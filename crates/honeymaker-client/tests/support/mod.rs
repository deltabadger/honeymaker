#![allow(dead_code)]
//! Local doubles for the transport tests: a TLS PKI, a scriptable target, an HTTP CONNECT proxy.
//! Each double counts connections and the request bytes it received, so a test can prove that a
//! failure classed as pre-transmission really sent nothing.
use rcgen::{BasicConstraints, CertificateParams, IsCa, KeyPair};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use std::net::SocketAddr;
use std::sync::atomic::{AtomicUsize, Ordering::SeqCst};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio_rustls::TlsAcceptor;

pub struct Pki {
    pub roots: Arc<rustls::RootCertStore>,
    pub trusted: TlsAcceptor,
    pub untrusted: TlsAcceptor,
}

fn provider() -> Arc<rustls::crypto::CryptoProvider> {
    Arc::new(rustls::crypto::ring::default_provider())
}

/// A CA and a leaf for localhost/127.0.0.1 signed by it.
fn issue() -> (
    CertificateDer<'static>,
    CertificateDer<'static>,
    PrivateKeyDer<'static>,
) {
    let ca_key = KeyPair::generate().unwrap();
    let mut ca = CertificateParams::new(Vec::<String>::new()).unwrap();
    ca.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    let ca_cert = ca.self_signed(&ca_key).unwrap();
    let leaf_key = KeyPair::generate().unwrap();
    let leaf = CertificateParams::new(vec!["localhost".to_string(), "127.0.0.1".to_string()])
        .unwrap()
        .signed_by(&leaf_key, &ca_cert, &ca_key)
        .unwrap();
    let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(leaf_key.serialize_der()));
    (ca_cert.der().clone(), leaf.der().clone(), key)
}

fn acceptor(leaf: CertificateDer<'static>, key: PrivateKeyDer<'static>) -> TlsAcceptor {
    let cfg = rustls::ServerConfig::builder_with_provider(provider())
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(vec![leaf], key)
        .unwrap();
    TlsAcceptor::from(Arc::new(cfg))
}

pub fn pki() -> Pki {
    let (ca, leaf, key) = issue();
    let (_unknown_ca, bad_leaf, bad_key) = issue();
    let mut roots = rustls::RootCertStore::empty();
    roots.add(ca).unwrap();
    Pki {
        roots: Arc::new(roots),
        trusted: acceptor(leaf, key),
        untrusted: acceptor(bad_leaf, bad_key),
    }
}

#[derive(Clone, Default)]
pub struct Seen {
    conns: Arc<AtomicUsize>,
    request_bytes: Arc<AtomicUsize>,
    heads: Arc<Mutex<Vec<String>>>,
    /// Set once a whole request has been read: every byte the double writes after it is the reply.
    answering: Arc<std::sync::atomic::AtomicBool>,
    times: Arc<Mutex<Times>>,
}

/// When the double first got request bytes, when the request was complete, and when it answered.
#[derive(Clone, Copy, Debug, Default)]
pub struct Times {
    pub first_byte: Option<std::time::Instant>,
    pub request_done: Option<std::time::Instant>,
    pub replied: Option<std::time::Instant>,
}
impl Seen {
    pub fn conns(&self) -> usize {
        self.conns.load(SeqCst)
    }
    pub fn request_bytes(&self) -> usize {
        self.request_bytes.load(SeqCst)
    }
    /// Each request's head and body as text, lowercased (header names are case-insensitive).
    pub fn heads(&self) -> Vec<String> {
        self.heads.lock().unwrap().clone()
    }
    pub fn times(&self) -> Times {
        *self.times.lock().unwrap()
    }
    fn mark(&self, f: impl FnOnce(&mut Times)) {
        f(&mut self.times.lock().unwrap())
    }
}

pub struct Double {
    pub addr: SocketAddr,
    pub seen: Seen,
}
impl Double {
    pub fn https(&self) -> String {
        format!("https://127.0.0.1:{}", self.addr.port())
    }
    pub fn https_localhost(&self) -> String {
        format!("https://localhost:{}", self.addr.port())
    }
    pub fn http(&self) -> String {
        format!("http://127.0.0.1:{}", self.addr.port())
    }
}

/// A raw HTTP/1.1 response with a correct Content-Length.
pub fn http(status: &str, content_type: &str, body: &str) -> &'static str {
    Box::leak(
        format!("HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len())
            .into_boxed_str(),
    )
}

pub const OK_JSON: &str = r#"{"error":[],"result":{"a":1}}"#;

#[derive(Clone, Copy)]
pub enum Tls {
    Plain,
    Trusted,
    Untrusted,
    NeverHandshake,
    #[allow(clippy::enum_variant_names)] // Name prescribed by the shared test-double interface.
    NotTls,
    /// Trusted TLS, but the encrypted reply reaches the socket as the relay decides.
    Relayed(Relay),
}

/// How the encrypted bytes of the reply are passed to the client's socket.
#[derive(Clone, Copy)]
pub enum Relay {
    /// `chunk` bytes at a time, `ms` apart: records arrive fragmented but keep progressing.
    Trickle { chunk: usize, ms: u64 },
    /// The first `n` encrypted bytes of the reply, then nothing: a stall inside a record.
    StallAfter(usize),
    /// The client's raw TCP bytes are taken `chunk` at a time, `ms` apart, until `budget` bytes have
    /// passed; then the rest drains at full speed and the reply goes out untouched. Transmission
    /// keeps progressing for a known time, whatever chunk sizes TLS produces above it.
    ThrottleUpload {
        chunk: usize,
        ms: u64,
        budget: usize,
    },
}

#[derive(Clone, Copy)]
pub enum Act {
    Reply(&'static str),
    /// Read the request, then say nothing.
    Hang,
    /// Read the request, then close (FIN; under TLS without close_notify).
    Close,
    /// Read the request, then reset (RST).
    Reset,
    /// Read this many request bytes, then stop reading (the client's writes back up).
    ReadSomeThenStop(usize),
    /// A 200 promising 50 bytes, 4 sent, then close.
    Partial,
    /// The reply in 4 pieces with this many milliseconds between them.
    Trickle(&'static str, u64),
}

pub async fn closed_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .await
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

fn find(buf: &[u8], pat: &[u8]) -> Option<usize> {
    buf.windows(pat.len()).position(|w| w == pat)
}

/// The request's head (original case) and body; `seen.heads` gets both, lowercased.
pub(crate) async fn read_request<S: AsyncRead + Unpin>(
    s: &mut S,
    seen: &Seen,
) -> Option<(String, String)> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    let head_end = loop {
        if let Some(i) = find(&buf, b"\r\n\r\n") {
            break i + 4;
        }
        let n = s.read(&mut chunk).await.ok()?;
        if n == 0 {
            return None;
        }
        seen.mark(|t| {
            t.first_byte.get_or_insert_with(std::time::Instant::now);
        });
        seen.request_bytes.fetch_add(n, SeqCst);
        buf.extend_from_slice(&chunk[..n]);
    };
    let head = String::from_utf8_lossy(&buf[..head_end]).into_owned();
    let len = head
        .to_ascii_lowercase()
        .lines()
        .find_map(|l| {
            l.strip_prefix("content-length:")
                .map(|v| v.trim().parse::<usize>().unwrap_or(0))
        })
        .unwrap_or(0);
    while buf.len() < head_end + len {
        let n = s.read(&mut chunk).await.ok()?;
        if n == 0 {
            break;
        }
        seen.request_bytes.fetch_add(n, SeqCst);
        buf.extend_from_slice(&chunk[..n]);
    }
    let body = String::from_utf8_lossy(&buf[head_end..]).into_owned();
    seen.heads
        .lock()
        .unwrap()
        .push(format!("{head}{body}").to_ascii_lowercase());
    seen.mark(|t| t.request_done = Some(std::time::Instant::now()));
    seen.answering.store(true, SeqCst);
    Some((head, body))
}

async fn serve<S: AsyncRead + AsyncWrite + Unpin>(mut s: S, act: Act, seen: &Seen) {
    if let Act::ReadSomeThenStop(n) = act {
        let mut buf = vec![0u8; n];
        if s.read_exact(&mut buf).await.is_ok() {
            seen.request_bytes.fetch_add(n, SeqCst);
        }
        tokio::time::sleep(Duration::from_secs(30)).await;
        return;
    }
    if read_request(&mut s, seen).await.is_none() {
        return;
    }
    match act {
        Act::Reply(raw) => {
            let _ = s.write_all(raw.as_bytes()).await;
            seen.mark(|t| t.replied = Some(std::time::Instant::now()));
            let _ = s.shutdown().await;
        }
        Act::Hang => tokio::time::sleep(Duration::from_secs(30)).await,
        Act::Close | Act::Reset | Act::ReadSomeThenStop(_) => {}
        Act::Partial => {
            let _ = s
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 50\r\n\r\n{\"a\"")
                .await;
        }
        Act::Trickle(raw, ms) => {
            let step = raw.len().div_ceil(4);
            for piece in raw.as_bytes().chunks(step) {
                tokio::time::sleep(Duration::from_millis(ms)).await;
                if s.write_all(piece).await.is_err() {
                    return;
                }
            }
            let _ = s.shutdown().await;
        }
    }
}

pub async fn target(tls: Tls, act: Act, pki: &Pki) -> Double {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let seen = Seen::default();
    let (all, trusted, untrusted) = (seen.clone(), pki.trusted.clone(), pki.untrusted.clone());
    tokio::spawn(async move {
        while let Ok((tcp, _)) = listener.accept().await {
            all.conns.fetch_add(1, SeqCst);
            let (seen, trusted, untrusted) = (all.clone(), trusted.clone(), untrusted.clone());
            tokio::spawn(async move {
                if matches!(act, Act::Reset) {
                    #[allow(deprecated)]
                    let _ = tcp.set_linger(Some(Duration::ZERO));
                }
                match tls {
                    Tls::Plain => serve(tcp, act, &seen).await,
                    Tls::Trusted => {
                        if let Ok(s) = trusted.accept(tcp).await {
                            serve(s, act, &seen).await
                        }
                    }
                    Tls::Untrusted => {
                        let _ = untrusted.accept(tcp).await;
                    }
                    Tls::NeverHandshake => {
                        tokio::time::sleep(Duration::from_secs(30)).await;
                        drop(tcp)
                    }
                    Tls::NotTls => {
                        let mut tcp = tcp;
                        tokio::time::sleep(Duration::from_millis(50)).await;
                        let _ = tcp.write_all(b"garbage\r\n\r\n").await;
                    }
                    Tls::Relayed(relay) => relayed(tcp, relay, act, trusted, seen).await,
                }
            });
        }
    });
    Double { addr, seen }
}

/// TLS is served over an in-memory pipe; the relay copies the client's bytes straight in, and the
/// server's bytes out as `relay` says once the request has been read (so only the reply is shaped).
async fn relayed(tcp: TcpStream, relay: Relay, act: Act, acceptor: TlsAcceptor, seen: Seen) {
    let (server_side, relay_side) = tokio::io::duplex(1 << 16);
    let served = seen.clone();
    tokio::spawn(async move {
        if let Ok(s) = acceptor.accept(server_side).await {
            serve(s, act, &served).await
        }
    });
    let (mut tcp_r, mut tcp_w) = tcp.into_split();
    let (mut rel_r, mut rel_w) = tokio::io::split(relay_side);
    tokio::spawn(async move {
        let Relay::ThrottleUpload { chunk, ms, budget } = relay else {
            let _ = tokio::io::copy(&mut tcp_r, &mut rel_w).await;
            return;
        };
        let (mut piece, mut passed) = (vec![0u8; chunk], 0usize);
        loop {
            if passed < budget {
                tokio::time::sleep(Duration::from_millis(ms)).await;
            }
            let n = match tcp_r.read(&mut piece).await {
                Ok(0) | Err(_) => return,
                Ok(n) => n,
            };
            if rel_w.write_all(&piece[..n]).await.is_err() {
                return;
            }
            passed += n;
        }
    });
    let mut buf = vec![0u8; 16 * 1024];
    let mut sent_after = 0usize;
    loop {
        let n = match rel_r.read(&mut buf).await {
            Ok(0) | Err(_) => return,
            Ok(n) => n,
        };
        if !seen.answering.load(SeqCst) || matches!(relay, Relay::ThrottleUpload { .. }) {
            if tcp_w.write_all(&buf[..n]).await.is_err() {
                return;
            }
            continue;
        }
        match relay {
            Relay::Trickle { chunk, ms } => {
                for piece in buf[..n].chunks(chunk) {
                    tokio::time::sleep(Duration::from_millis(ms)).await;
                    if tcp_w.write_all(piece).await.is_err() {
                        return;
                    }
                }
            }
            Relay::ThrottleUpload { .. } => unreachable!("written above"),
            Relay::StallAfter(limit) => {
                let take = limit.saturating_sub(sent_after).min(n);
                let _ = tcp_w.write_all(&buf[..take]).await;
                sent_after += take;
                if sent_after >= limit {
                    tokio::time::sleep(Duration::from_secs(30)).await;
                    return;
                }
            }
        }
    }
}

#[derive(Clone, Copy)]
pub enum ProxyAct {
    /// Answer 200 and splice to this upstream.
    Tunnel(SocketAddr),
    /// Answer CONNECT with this raw response, then close.
    Answer(&'static str),
    Hang,
    Close,
}

/// An HTTP proxy that records each CONNECT head (lowercased) and acts.
pub async fn proxy(act: ProxyAct) -> Double {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let seen = Seen::default();
    let all = seen.clone();
    tokio::spawn(async move {
        while let Ok((mut s, _)) = listener.accept().await {
            all.conns.fetch_add(1, SeqCst);
            let seen = all.clone();
            tokio::spawn(async move {
                if read_request(&mut s, &seen).await.is_none() {
                    return;
                }
                match act {
                    ProxyAct::Tunnel(up) => {
                        let _ = s
                            .write_all(b"HTTP/1.1 200 Connection established\r\n\r\n")
                            .await;
                        if let Ok(mut u) = TcpStream::connect(up).await {
                            let _ = tokio::io::copy_bidirectional(&mut s, &mut u).await;
                        }
                    }
                    ProxyAct::Answer(raw) => {
                        let _ = s.write_all(raw.as_bytes()).await;
                        tokio::time::sleep(Duration::from_millis(200)).await;
                    }
                    ProxyAct::Hang => tokio::time::sleep(Duration::from_secs(30)).await,
                    ProxyAct::Close => {}
                }
            });
        }
    });
    Double { addr, seen }
}
