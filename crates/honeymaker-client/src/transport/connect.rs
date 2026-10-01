//! The connect phases, each bounded by the open timeout and each failing with its own cause:
//! resolve + TCP (target, or proxy), proxy CONNECT (Ruling R2), TLS handshake. The read/write
//! timeouts wrap the raw socket straight after connect, so they measure socket waits under TLS.
use super::io_timeout::{RequestIo, RequestProgress, Stall, TimeoutIo};
use super::{Cause, Failure, Proxy, Transport};
use std::{io, sync::Arc, time::Duration};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::{TcpStream, lookup_host};
use tokio::time::timeout;
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
    let tcp = open_tcp(host, port, t.timeouts.open, tcp(host, port)).await?;
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
    limit: Duration,
    connect: impl std::future::Future<Output = Result<T, Failure>>,
) -> Result<T, Failure> {
    timeout(limit, connect).await.map_err(|_| {
        Failure::new(Cause::OpenTimeout,
            format!("Failed to open TCP connection to {host}:{port} (user specified timeout for {host}:{port})"))
    })?
}

async fn tcp(host: &str, port: u16) -> Result<TcpStream, Failure> {
    let mut addrs = lookup_host((host, port)).await.map_err(|e| {
        Failure::new(
            Cause::Dns,
            format!("Failed to open TCP connection to {host}:{port} (getaddrinfo: {e})"),
        )
    })?;
    // One connection attempt, including when DNS supplies several addresses.
    let Some(addr) = addrs.next() else {
        return Err(Failure::new(
            Cause::Dns,
            format!("Failed to open TCP connection to {host}:{port} (no address)"),
        ));
    };
    let e = match TcpStream::connect(addr).await {
        Ok(s) => return Ok(s),
        Err(e) => e,
    };
    use io::ErrorKind::*;
    Err(match e.kind() {
        ConnectionRefused => {
            Failure::new(Cause::Refused, format!("connection refused: {host}:{port}"))
        }
        HostUnreachable | NetworkUnreachable | NetworkDown | AddrNotAvailable => Failure::new(
            Cause::Unreachable,
            format!("Failed to open TCP connection to {host}:{port} ({e})"),
        ),
        _ => Failure::new(
            Cause::Other,
            format!("Failed to open TCP connection to {host}:{port} ({e})"),
        ),
    })
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
        let failure = tcp("localhost\0", 443).await.unwrap_err();
        assert_eq!(failure.cause, Cause::Dns);
        assert!(failure.pre_transmission());
    }

    #[tokio::test(start_paused = true)]
    async fn a_stalled_connector_is_bounded_by_the_open_timeout() {
        let started = tokio::time::Instant::now();
        let failure = open_tcp(
            "127.0.0.1",
            443,
            Duration::from_millis(300),
            std::future::pending::<Result<TcpStream, Failure>>(),
        )
        .await
        .unwrap_err();
        assert_eq!(failure.cause, Cause::OpenTimeout);
        assert!(failure.pre_transmission());
        assert_eq!(started.elapsed(), Duration::from_millis(300));
    }
}
