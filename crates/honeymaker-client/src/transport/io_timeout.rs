//! Net::HTTP's read_timeout / write_timeout: a limit on each wait for the socket, not on the whole
//! exchange. A peer that keeps sending, however slowly, never times out.
use std::future::Future;
use std::io;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering::SeqCst};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::time::{Sleep, sleep};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Stall {
    Read,
    Write,
}
impl std::fmt::Display for Stall {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Stall::Read => "Net::ReadTimeout",
            Stall::Write => "Net::WriteTimeout",
        })
    }
}
impl std::error::Error for Stall {}

/// Shared across the HTTP body, the TLS stream, and the raw socket below TLS.
/// A body queued by hyper is not yet transmitted: only the subsequent successful
/// flush above TLS can enable response timeouts below TLS.
#[derive(Default)]
pub(crate) struct RequestProgress {
    queued: AtomicBool,
    flushed: AtomicBool,
    reader: Mutex<Option<Waker>>,
}
impl RequestProgress {
    pub(crate) fn body_queued(&self) {
        self.queued.store(true, SeqCst);
    }

    fn flushed(&self) {
        let mut reader = self.reader.lock().unwrap();
        if self.queued.load(SeqCst)
            && !self.flushed.swap(true, SeqCst)
            && let Some(waker) = reader.take()
        {
            waker.wake();
        }
    }

    fn can_read(&self, cx: &Context<'_>) -> bool {
        let mut reader = self.reader.lock().unwrap();
        if self.flushed.load(SeqCst) {
            return true;
        }
        *reader = Some(cx.waker().clone());
        false
    }
}

/// Observes flush completion above TLS, after hyper has drained its HTTP buffer.
pub(crate) struct RequestIo<S> {
    inner: S,
    progress: Arc<RequestProgress>,
    wrote: bool,
}
impl<S> RequestIo<S> {
    pub(crate) fn new(inner: S, progress: Arc<RequestProgress>) -> Self {
        Self {
            inner,
            progress,
            wrote: false,
        }
    }
}
impl<S: AsyncRead + Unpin> AsyncRead for RequestIo<S> {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_read(cx, buf)
    }
}
impl<S: AsyncWrite + Unpin> AsyncWrite for RequestIo<S> {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        let this = self.get_mut();
        let result = Pin::new(&mut this.inner).poll_write(cx, buf);
        if matches!(result, Poll::Ready(Ok(n)) if n > 0) {
            this.wrote = true;
        }
        result
    }
    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        let result = Pin::new(&mut this.inner).poll_flush(cx);
        if this.wrote && matches!(result, Poll::Ready(Ok(()))) {
            this.progress.flushed();
        }
        result
    }
    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_shutdown(cx)
    }
}

pub(crate) struct TimeoutIo<S> {
    inner: S,
    progress: Option<Arc<RequestProgress>>,
    read: Duration,
    write: Duration,
    read_timer: Option<Pin<Box<Sleep>>>,
    write_timer: Option<Pin<Box<Sleep>>>,
    /// A write is waiting on the socket: the request is still being transmitted.
    writing: bool,
}

impl<S> TimeoutIo<S> {
    pub(crate) fn new(inner: S, read: Duration, write: Duration) -> Self {
        Self {
            inner,
            progress: None,
            read,
            write,
            read_timer: None,
            write_timer: None,
            writing: false,
        }
    }

    pub(crate) fn for_request(
        inner: S,
        read: Duration,
        write: Duration,
        progress: Arc<RequestProgress>,
    ) -> Self {
        Self {
            progress: Some(progress),
            ..Self::new(inner, read, write)
        }
    }

    /// A write finished. If it moved bytes (or ends a wait), transmission progressed, so the
    /// response wait starts afresh from now: Net::HTTP only starts reading once it has written.
    /// The existing Sleep is reset rather than dropped, so it keeps the reader's waker.
    fn wrote(&mut self, progressed: bool) {
        self.write_timer = None;
        if (progressed || self.writing)
            && let Some(t) = self.read_timer.as_mut()
        {
            t.as_mut().reset(tokio::time::Instant::now() + self.read);
        }
        self.writing = false;
    }
}

fn stalled<T>(
    timer: &mut Option<Pin<Box<Sleep>>>,
    limit: Duration,
    which: Stall,
    cx: &mut Context<'_>,
) -> Poll<io::Result<T>> {
    let t = timer.get_or_insert_with(|| Box::pin(sleep(limit)));
    match t.as_mut().poll(cx) {
        Poll::Ready(()) => {
            *timer = None;
            Poll::Ready(Err(io::Error::new(io::ErrorKind::TimedOut, which)))
        }
        Poll::Pending => Poll::Pending,
    }
}

impl<S: AsyncRead + Unpin> AsyncRead for TimeoutIo<S> {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        match Pin::new(&mut this.inner).poll_read(cx, buf) {
            Poll::Ready(r) => {
                this.read_timer = None;
                Poll::Ready(r)
            }
            // While the request is still going out, a read wait is not a response wait (hyper
            // polls reads alongside writes); the write timer governs until the write completes.
            Poll::Pending if this.progress.as_ref().is_some_and(|p| !p.can_read(cx)) => {
                Poll::Pending
            }
            Poll::Pending if this.writing => Poll::Pending,
            Poll::Pending => stalled(&mut this.read_timer, this.read, Stall::Read, cx),
        }
    }
}

impl<S: AsyncWrite + Unpin> TimeoutIo<S> {
    fn write_side<T>(
        &mut self,
        cx: &mut Context<'_>,
        poll: Poll<io::Result<T>>,
        progressed: impl FnOnce(&T) -> bool,
    ) -> Poll<io::Result<T>> {
        match poll {
            Poll::Ready(Ok(v)) => {
                self.wrote(progressed(&v));
                Poll::Ready(Ok(v))
            }
            Poll::Ready(Err(e)) => {
                self.write_timer = None;
                self.writing = false;
                Poll::Ready(Err(e))
            }
            Poll::Pending => {
                self.writing = true;
                stalled(&mut self.write_timer, self.write, Stall::Write, cx)
            }
        }
    }
}

impl<S: AsyncWrite + Unpin> AsyncWrite for TimeoutIo<S> {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        let this = self.get_mut();
        let poll = Pin::new(&mut this.inner).poll_write(cx, buf);
        this.write_side(cx, poll, |n| *n > 0)
    }
    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        let poll = Pin::new(&mut this.inner).poll_flush(cx);
        this.write_side(cx, poll, |_| false)
    }
    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        let poll = Pin::new(&mut this.inner).poll_shutdown(cx);
        this.write_side(cx, poll, |_| false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt, duplex};

    fn stall_of(e: &io::Error) -> Option<Stall> {
        e.get_ref().and_then(|x| x.downcast_ref::<Stall>()).copied()
    }

    #[tokio::test(start_paused = true)]
    async fn a_silent_peer_times_out_after_the_read_limit() {
        let (a, _b) = duplex(64);
        let mut io = TimeoutIo::new(a, Duration::from_secs(30), Duration::from_secs(10));
        let started = tokio::time::Instant::now();
        let e = io.read(&mut [0u8; 8]).await.unwrap_err();
        assert_eq!(
            (e.kind(), stall_of(&e)),
            (io::ErrorKind::TimedOut, Some(Stall::Read))
        );
        assert_eq!(started.elapsed(), Duration::from_secs(30));
    }

    #[tokio::test(start_paused = true)]
    async fn a_slow_but_steady_peer_never_times_out() {
        let (a, mut b) = duplex(64);
        tokio::spawn(async move {
            for _ in 0..5 {
                sleep(Duration::from_secs(29)).await;
                b.write_all(b"x").await.unwrap();
            }
        });
        let mut io = TimeoutIo::new(a, Duration::from_secs(30), Duration::from_secs(10));
        let mut buf = [0u8; 5];
        io.read_exact(&mut buf).await.unwrap();
        assert_eq!(&buf, b"xxxxx");
    }

    #[tokio::test(start_paused = true)]
    async fn write_progress_restarts_the_response_wait() {
        let (a, _b) = duplex(64);
        let io = TimeoutIo::new(a, Duration::from_secs(30), Duration::from_secs(10));
        let (mut r, mut w) = tokio::io::split(io);
        let started = tokio::time::Instant::now();
        let reader = async { r.read(&mut [0u8; 8]).await.unwrap_err() };
        let writer = async {
            sleep(Duration::from_secs(20)).await;
            w.write_all(b"x").await.unwrap(); // the request's last byte goes out at 20 s
        };
        let (e, ()) = tokio::join!(reader, writer);
        assert_eq!(stall_of(&e), Some(Stall::Read));
        assert_eq!(
            started.elapsed(),
            Duration::from_secs(50),
            "30 s after the last write, not after the first read"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_peer_that_stops_reading_times_out_the_write() {
        let (a, _b) = duplex(8);
        let mut io = TimeoutIo::new(a, Duration::from_secs(30), Duration::from_secs(10));
        let e = io.write_all(&[0u8; 64]).await.unwrap_err();
        assert_eq!(stall_of(&e), Some(Stall::Write));
    }
}

#[cfg(test)]
mod completion_tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt, duplex};

    #[tokio::test(start_paused = true)]
    async fn response_wait_starts_only_after_the_complete_request_is_flushed() {
        let (a, _peer) = duplex(64);
        let progress = Arc::new(RequestProgress::default());
        let raw = TimeoutIo::for_request(
            a,
            Duration::from_secs(30),
            Duration::from_secs(10),
            progress.clone(),
        );
        let io = RequestIo::new(raw, progress.clone());
        let (mut reader, mut writer) = tokio::io::split(io);
        let started = tokio::time::Instant::now();
        let read = async { reader.read(&mut [0; 1]).await.unwrap_err() };
        let write = async {
            // An initial flush and a partial request must not enable the response timer.
            writer.flush().await.unwrap();
            writer.write_all(b"head").await.unwrap();
            writer.flush().await.unwrap();
            sleep(Duration::from_secs(40)).await;
            progress.body_queued();
            writer.write_all(b"body").await.unwrap();
            // Even when all plaintext is accepted, wait until TLS has flushed it.
            sleep(Duration::from_secs(40)).await;
            writer.flush().await.unwrap();
        };
        let (err, ()) = tokio::join!(read, write);
        assert_eq!(
            err.get_ref().unwrap().downcast_ref::<Stall>(),
            Some(&Stall::Read)
        );
        assert_eq!(started.elapsed(), Duration::from_secs(110));
    }
}
