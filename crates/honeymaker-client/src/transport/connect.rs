//! The connect phases, each bounded by the open timeout and each failing with its own cause:
//! resolve + TCP (target, or proxy), proxy CONNECT (Ruling R2), TLS handshake. The read/write
//! timeouts wrap the raw socket straight after connect, so they measure socket waits under TLS.
use super::io_timeout::{RequestIo, RequestProgress, Stall, TimeoutIo};
use super::{Cause, Failure, Proxy, Transport};
use std::{
    future::{Future, poll_fn},
    io,
    net::SocketAddr,
    pin::Pin,
    sync::Arc,
    task::Poll,
    time::Duration,
};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::{TcpStream, lookup_host};
use tokio::time::{Instant, sleep_until, timeout, timeout_at};
use tokio_rustls::TlsConnector;

pub(crate) trait Io: AsyncRead + AsyncWrite + Send + Unpin {}
impl<T: AsyncRead + AsyncWrite + Send + Unpin> Io for T {}

pub(crate) async fn connect(
    t: &Transport,
    progress: Arc<RequestProgress>,
) -> Result<Box<dyn Io>, Failure> {
    let (host, port) = match &t.proxy {
        Some(p) => (p.host.as_str(), p.port),
        None => (t.target.host.as_str(), t.target.port),
    };
    let deadline = Instant::now() + t.timeouts.open;
    let tcp = open_tcp(host, port, deadline, tcp(host, port, deadline)).await?;
    let mut tcp = TimeoutIo::for_request(tcp, t.timeouts.read, t.timeouts.write, progress.clone());
    if let Some(p) = &t.proxy {
        let connect_timeout =
            || Failure::new(Cause::OpenTimeout, "Net::OpenTimeout (proxy CONNECT)");
        timeout(t.timeouts.open, tunnel(&mut tcp, p, &t.target.authority()))
            .await
            .map_err(|_| connect_timeout())?
            .map_err(|f| if is_stall(&f) { connect_timeout() } else { f })?;
    }
    if !t.target.tls {
        return Ok(Box::new(RequestIo::new(tcp, progress)));
    }
    let tls = timeout(
        t.timeouts.open,
        TlsConnector::from(t.tls.clone()).connect(t.server_name.clone(), tcp),
    )
    .await
    .map_err(|_| Failure::new(Cause::OpenTimeout, "Net::OpenTimeout"))?
    .map_err(|e| handshake_failure(&e))?;
    Ok(Box::new(RequestIo::new(tls, progress)))
}

async fn open_tcp<T>(
    host: &str,
    port: u16,
    deadline: Instant,
    connect: impl std::future::Future<Output = Result<T, Failure>>,
) -> Result<T, Failure> {
    timeout_at(deadline, connect).await.map_err(|_| {
        Failure::new(Cause::OpenTimeout,
            format!("Failed to open TCP connection to {host}:{port} (user specified timeout for {host}:{port})"))
    })?
}

async fn tcp(host: &str, port: u16, deadline: Instant) -> Result<TcpStream, Failure> {
    let addrs: Vec<_> = lookup_host((host, port))
        .await
        .map_err(|e| {
            Failure::new(
                Cause::Dns,
                format!("Failed to open TCP connection to {host}:{port} (getaddrinfo: {e})"),
            )
        })?
        .collect();
    if addrs.is_empty() {
        return Err(Failure::new(
            Cause::Dns,
            format!("Failed to open TCP connection to {host}:{port} (no address)"),
        ));
    }
    connect_any(&addrs, deadline)
        .await
        .map_err(|e| tcp_failure(host, port, &e))
}

async fn connect_any(addrs: &[SocketAddr], deadline: Instant) -> io::Result<TcpStream> {
    connect_any_with(addrs, deadline, TcpStream::connect).await
}

async fn connect_any_with<T, F: Future<Output = io::Result<T>>>(
    addrs: &[SocketAddr],
    deadline: Instant,
    mut connector: impl FnMut(SocketAddr) -> F,
) -> io::Result<T> {
    // All attempts belong to this future: returning a winner or timing out drops the rest.
    // Only TCP connects happen here; TLS, proxy CONNECT and request writes use the winner.
    let mut attempts: Vec<Option<Pin<Box<F>>>> = Vec::new();
    let mut next = 0;
    let mut last_error = None;
    let mut expires = Box::pin(sleep_until(deadline));
    let mut next_attempt = Box::pin(sleep_until(Instant::now()));
    poll_fn(|cx| {
        loop {
            // Check before starting or accepting an attempt, including at the deadline itself.
            if expires.as_mut().poll(cx).is_ready() {
                return Poll::Ready(Err(io::Error::from(io::ErrorKind::TimedOut)));
            }
            for attempt in &mut attempts {
                let Some(future) = attempt else {
                    continue;
                };
                if let Poll::Ready(result) = future.as_mut().poll(cx) {
                    *attempt = None;
                    match result {
                        Ok(stream) => return Poll::Ready(Ok(stream)),
                        Err(error) => last_error = Some(error),
                    }
                }
            }
            if next < addrs.len() && next_attempt.as_mut().poll(cx).is_ready() {
                attempts.push(Some(Box::pin(connector(addrs[next]))));
                next += 1;
                next_attempt
                    .as_mut()
                    .reset(Instant::now() + Duration::from_millis(250));
                continue;
            }
            if next == addrs.len() && attempts.iter().all(Option::is_none) {
                return Poll::Ready(Err(last_error.take().unwrap_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidInput, "no address")
                })));
            }
            return Poll::Pending;
        }
    })
    .await
}

fn tcp_failure(host: &str, port: u16, e: &io::Error) -> Failure {
    use io::ErrorKind::*;
    match e.kind() {
        ConnectionRefused => {
            Failure::new(Cause::Refused, format!("connection refused: {host}:{port}"))
        }
        TimedOut => Failure::new(
            Cause::OpenTimeout,
            format!("Failed to open TCP connection to {host}:{port} ({e})"),
        ),
        HostUnreachable | NetworkUnreachable | NetworkDown | AddrNotAvailable => Failure::new(
            Cause::Unreachable,
            format!("Failed to open TCP connection to {host}:{port} ({e})"),
        ),
        _ => Failure::new(
            Cause::Other,
            format!("Failed to open TCP connection to {host}:{port} ({e})"),
        ),
    }
}

/// HTTP CONNECT as Net::HTTP sends it; the answer's status line decides.
/// A socket-wait timeout before any request byte was written is the open phase's timeout (R21).
fn is_stall(f: &Failure) -> bool {
    matches!(f.cause, Cause::ReadTimeout | Cause::WriteTimeout)
}

async fn tunnel<S: AsyncRead + AsyncWrite + Unpin>(
    s: &mut S,
    p: &Proxy,
    authority: &str,
) -> Result<(), Failure> {
    let mut req = format!("CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\n");
    if let Some(a) = &p.authorization {
        req.push_str(&format!("Proxy-Authorization: {a}\r\n"));
    }
    req.push_str("\r\n");
    s.write_all(req.as_bytes())
        .await
        .map_err(|e| io_failure(&e))?;
    // Read one byte at a time so no tunnel byte is buffered past the head; the head is tiny.
    let mut head = Vec::new();
    while !head.ends_with(b"\r\n\r\n") {
        if head.len() >= 16 * 1024 {
            return Err(Failure::new(
                Cause::ProxyFailed,
                "proxy CONNECT answer too large",
            ));
        }
        let mut b = [0u8; 1];
        match s.read(&mut b).await {
            Ok(0) => return Err(Failure::new(Cause::Eof, "end of file reached")),
            Ok(_) => head.push(b[0]),
            Err(e) => return Err(io_failure(&e)),
        }
    }
    let text = String::from_utf8_lossy(&head);
    let line = text.lines().next().unwrap_or("");
    let mut parts = line.splitn(3, ' ');
    let (version, code, reason) = (parts.next(), parts.next(), parts.next().unwrap_or(""));
    if !matches!(version, Some("HTTP/1.0" | "HTTP/1.1"))
        || !code.is_some_and(|c| c.len() == 3 && c.bytes().all(|b| b.is_ascii_digit()))
    {
        return Err(Failure::new(
            Cause::ProxyFailed,
            format!("wrong status line: {line:?}"),
        ));
    }
    for header in text.split("\r\n").skip(1).take_while(|l| !l.is_empty()) {
        let valid = header.split_once(':').is_some_and(|(name, value)| {
            hyper::header::HeaderName::from_bytes(name.as_bytes()).is_ok()
                && hyper::header::HeaderValue::from_str(value.trim()).is_ok()
        });
        if !valid {
            return Err(Failure::new(
                Cause::ProxyFailed,
                "malformed proxy CONNECT headers",
            ));
        }
    }
    let code = code.and_then(|c| c.parse::<u16>().ok());
    match code {
        Some(c) if (200..300).contains(&c) => Ok(()),
        // Net::HTTPResponse#value: 4xx is HTTPClientException; its message is `code "reason"`.
        Some(c) if (400..500).contains(&c) => Err(Failure::new(
            Cause::ProxyRefused(c),
            format!("{c} {reason:?}"),
        )),
        Some(c) => Err(Failure::new(Cause::ProxyFailed, format!("{c} {reason:?}"))),
        None => Err(Failure::new(
            Cause::ProxyFailed,
            format!("wrong status line: {line:?}"),
        )),
    }
}

/// A socket error after the connection is up.
pub(crate) fn io_failure(e: &io::Error) -> Failure {
    if let Some(stall) = e.get_ref().and_then(|x| x.downcast_ref::<Stall>()) {
        return match stall {
            Stall::Read => Failure::new(Cause::ReadTimeout, "Net::ReadTimeout"),
            Stall::Write => Failure::new(Cause::WriteTimeout, "Net::WriteTimeout"),
        };
    }
    match e.kind() {
        io::ErrorKind::UnexpectedEof => Failure::new(Cause::Eof, "end of file reached"),
        io::ErrorKind::ConnectionReset => {
            Failure::new(Cause::Reset, format!("Connection reset by peer ({e})"))
        }
        io::ErrorKind::InvalidData if e.get_ref().is_some_and(|x| x.is::<rustls::Error>()) => {
            Failure::new(Cause::Tls, format!("SSL error: {e}"))
        }
        _ => Failure::new(Cause::Other, e.to_string()),
    }
}

/// Any TLS handshake failure other than its timeout is Cause::Tls (Ruby: OpenSSL::SSL::SSLError).
fn handshake_failure(e: &io::Error) -> Failure {
    match io_failure(e) {
        f if is_stall(&f) => Failure::new(Cause::OpenTimeout, "Net::OpenTimeout"),
        f if f.cause == Cause::Reset => f,
        f => Failure::new(Cause::Tls, format!("SSL_connect: {}", f.message)),
    }
}

/// Never let the legacy message fallback turn a post-send socket failure into
/// permission to retry. The exception's kind is retained without its misleading text.
fn exchange_io_failure(e: &io::Error) -> Failure {
    let failure = io_failure(e);
    if failure.pre_transmission() {
        Failure::new(
            Cause::Other,
            format!("request exchange I/O error ({:?})", e.kind()),
        )
    } else {
        failure
    }
}

/// A failure hyper reports during the exchange: the first io::Error in its source chain decides,
/// else an incomplete message is end-of-file. All of these are post-send, hence ambiguous.
pub(crate) fn hyper_failure(e: &hyper::Error) -> Failure {
    let mut src: Option<&(dyn std::error::Error + 'static)> = Some(e);
    while let Some(s) = src {
        if let Some(io) = s.downcast_ref::<io::Error>() {
            return exchange_io_failure(io);
        }
        src = s.source();
    }
    if e.is_incomplete_message() {
        return Failure::new(Cause::Eof, "end of file reached");
    }
    Failure::new(Cause::Other, e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    use crate::kraken::{VenueError, outcome};
    use std::cell::{Cell, RefCell};
    use std::rc::Rc;
    use tokio::net::TcpListener;

    fn addresses() -> [SocketAddr; 3] {
        [1, 2, 3].map(|port| SocketAddr::from(([127, 0, 0, 1], port)))
    }

    fn refused_address() -> SocketAddr {
        // Drop a listening socket: a merely bound socket can black-hole SYNs on macOS.
        std::net::TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
    }

    struct Dropped(Rc<Cell<usize>>);
    impl Drop for Dropped {
        fn drop(&mut self) {
            self.0.set(self.0.get() + 1);
        }
    }

    #[tokio::test]
    async fn a_refused_address_falls_back_without_writing_any_bytes() {
        let refused = refused_address();
        let live = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addrs = [refused, live.local_addr().unwrap()];
        let stream = connect_any(&addrs, Instant::now() + Duration::from_secs(2))
            .await
            .unwrap();
        assert_eq!(stream.peer_addr().unwrap(), addrs[1]);
        let (mut accepted, _) = live.accept().await.unwrap();
        drop(stream);
        assert_eq!(accepted.read(&mut [0; 1]).await.unwrap(), 0);
        assert!(
            timeout(Duration::from_millis(30), live.accept())
                .await
                .is_err()
        );
        // The refused socket never establishes a stream, so it cannot receive request bytes.
    }

    #[tokio::test]
    async fn a_stalled_address_does_not_block_a_live_listener() {
        let live = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addrs = [addresses()[0], live.local_addr().unwrap()];
        let started = Instant::now();
        let stream = connect_any_with(
            &addrs,
            started + Duration::from_secs(2),
            |addr| async move {
                if addr == addrs[0] {
                    std::future::pending::<()>().await;
                }
                TcpStream::connect(addr).await
            },
        )
        .await
        .unwrap();
        assert!(started.elapsed() >= Duration::from_millis(250));
        assert!(started.elapsed() < Duration::from_secs(1));
        let (mut accepted, _) = live.accept().await.unwrap();
        drop(stream);
        assert_eq!(accepted.read(&mut [0; 1]).await.unwrap(), 0);
        assert!(
            timeout(Duration::from_millis(30), live.accept())
                .await
                .is_err()
        );
    }

    #[tokio::test(start_paused = true)]
    async fn attempts_are_staggered_and_the_first_success_drops_pending_attempts() {
        for winner in [1, 2] {
            let addrs = addresses();
            let started = Instant::now();
            let starts = RefCell::new(Vec::new());
            let dropped = Rc::new(Cell::new(0));
            let connected = connect_any_with(&addrs, started + Duration::from_secs(2), |addr| {
                starts.borrow_mut().push((addr, started.elapsed()));
                let guard = Dropped(dropped.clone());
                async move {
                    let _guard = guard;
                    if addr != addrs[winner] {
                        std::future::pending::<()>().await;
                    }
                    Ok(addr)
                }
            })
            .await
            .unwrap();
            assert_eq!(connected, addrs[winner]);
            assert_eq!(
                started.elapsed(),
                Duration::from_millis(250 * winner as u64)
            );
            assert_eq!(
                *starts.borrow(),
                addrs[..=winner]
                    .iter()
                    .enumerate()
                    .map(|(i, addr)| (*addr, Duration::from_millis(250 * i as u64)))
                    .collect::<Vec<_>>()
            );
            assert_eq!(dropped.get(), winner + 1, "no attempt survives the winner");
        }
    }

    #[tokio::test]
    async fn all_refused_addresses_are_attempted_and_classed_transient() {
        let addrs = [refused_address(), refused_address()];
        let attempted = RefCell::new(Vec::new());
        let error = connect_any_with(&addrs, Instant::now() + Duration::from_secs(2), |addr| {
            attempted.borrow_mut().push(addr);
            TcpStream::connect(addr)
        })
        .await
        .unwrap_err();
        assert_eq!(*attempted.borrow(), addrs);
        let failure = tcp_failure("localhost", addrs[0].port(), &error);
        assert_eq!(failure.cause, Cause::Refused);
        assert!(matches!(
            outcome(Err(failure)),
            Err(VenueError::Transient(_))
        ));
    }

    #[tokio::test(start_paused = true)]
    async fn all_failures_return_the_last_completed_error() {
        let addrs = addresses();
        let started = Instant::now();
        let error = connect_any_with(
            &addrs[..2],
            started + Duration::from_secs(1),
            |addr| async move {
                let kind = if addr == addrs[0] {
                    tokio::time::sleep(Duration::from_millis(600)).await;
                    io::ErrorKind::PermissionDenied
                } else {
                    io::ErrorKind::ConnectionRefused
                };
                Err::<(), _>(io::Error::from(kind))
            },
        )
        .await
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(started.elapsed(), Duration::from_millis(600));
    }

    #[tokio::test(start_paused = true)]
    async fn resolution_and_all_attempts_share_one_open_deadline() {
        for limit in [200, 600] {
            let started = Instant::now();
            let deadline = started + Duration::from_millis(limit);
            let starts = RefCell::new(Vec::new());
            let dropped = Rc::new(Cell::new(0));
            let failure = open_tcp("localhost", 443, deadline, async {
                // Deterministic stand-in for time spent resolving the host.
                tokio::time::sleep(Duration::from_millis(100)).await;
                connect_any_with(&addresses(), deadline, |_| {
                    starts.borrow_mut().push(started.elapsed());
                    let guard = Dropped(dropped.clone());
                    async move {
                        let _guard = guard;
                        std::future::pending::<io::Result<()>>().await
                    }
                })
                .await
                .map_err(|e| tcp_failure("localhost", 443, &e))
            })
            .await
            .unwrap_err();
            assert_eq!(failure.cause, Cause::OpenTimeout);
            assert!(failure.pre_transmission());
            assert_eq!(started.elapsed(), Duration::from_millis(limit));
            let expected = if limit == 200 {
                vec![100]
            } else {
                vec![100, 350]
            };
            assert_eq!(
                *starts.borrow(),
                expected
                    .into_iter()
                    .map(Duration::from_millis)
                    .collect::<Vec<_>>()
            );
            assert_eq!(dropped.get(), starts.borrow().len());
        }
    }

    #[test]
    fn a_kernel_connect_timeout_is_an_open_timeout_and_transient() {
        let failure = tcp_failure("localhost", 443, &io::Error::from(io::ErrorKind::TimedOut));
        assert_eq!(failure.cause, Cause::OpenTimeout);
        assert!(matches!(
            outcome(Err(failure)),
            Err(VenueError::Transient(_))
        ));
        // The same errno after connection establishment is still ambiguous.
        assert!(!exchange_io_failure(&io::Error::from(io::ErrorKind::TimedOut)).pre_transmission());
    }

    #[test]
    fn an_exchange_error_cannot_become_transient_from_its_message() {
        let failure = exchange_io_failure(&io::Error::new(
            io::ErrorKind::ConnectionRefused,
            "connection refused",
        ));
        assert!(!failure.pre_transmission());
        assert_eq!(failure.cause, Cause::Other);
    }

    #[tokio::test]
    async fn local_resolver_rejection_is_pre_transmission() {
        // Embedded NUL is rejected by getaddrinfo before any DNS traffic.
        let failure = tcp("localhost\0", 443, Instant::now() + Duration::from_secs(1))
            .await
            .unwrap_err();
        assert_eq!(failure.cause, Cause::Dns);
        assert!(failure.pre_transmission());
    }

    #[tokio::test(start_paused = true)]
    async fn a_stalled_connector_is_bounded_by_the_open_timeout() {
        let started = tokio::time::Instant::now();
        let failure = open_tcp(
            "127.0.0.1",
            443,
            started + Duration::from_millis(300),
            std::future::pending::<Result<TcpStream, Failure>>(),
        )
        .await
        .unwrap_err();
        assert_eq!(failure.cause, Cause::OpenTimeout);
        assert!(failure.pre_transmission());
        assert_eq!(started.elapsed(), Duration::from_millis(300));
    }
}
