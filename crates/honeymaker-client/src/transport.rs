//! One HTTP request over its own connection, with every failure tagged by the phase it happened
//! in. The tags are the causes Ruby's exception chain would name, because deltabadger decides
//! "did the request leave?" from those (Client.pre_transmission?).

/// The most specific cause, in Client::PREFERRED_CAUSE_PATTERNS' terms.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Cause {
    /// Socket::ResolutionError: the name did not resolve.
    Dns,
    /// Errno::ECONNREFUSED (the target, or the proxy).
    Refused,
    /// Errno::EHOSTUNREACH / ENETUNREACH / ENETDOWN / EADDRNOTAVAIL.
    Unreachable,
    /// Net::OpenTimeout: TCP connect, TLS handshake, or (Ruling R2) proxy CONNECT.
    OpenTimeout,
    /// Net::HTTPClientException: the proxy answered CONNECT with 4xx.
    ProxyRefused(u16),
    /// Any other CONNECT answer that is not 2xx, or a malformed one (Net::HTTPFatalError, …).
    ProxyFailed,
    /// OpenSSL::SSL::SSLError: a TLS failure, in the handshake or later.
    Tls,
    /// Net::ReadTimeout.
    ReadTimeout,
    /// Net::WriteTimeout.
    WriteTimeout,
    /// EOFError.
    Eof,
    /// Errno::ECONNRESET.
    Reset,
    /// Anything else: provenance unknown, so assume it may have landed.
    Other,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Failure {
    pub cause: Cause,
    pub message: String,
}

impl Failure {
    pub fn new(cause: Cause, message: impl Into<String>) -> Self {
        Self {
            cause,
            message: message.into(),
        }
    }

    /// Client.pre_transmission?: the cause is one Client::PRE_TRANSMISSION_ERRORS names, or the
    /// text says the connection was refused. Only then did the request provably never leave.
    pub fn pre_transmission(&self) -> bool {
        matches!(
            self.cause,
            Cause::Dns
                | Cause::Refused
                | Cause::Unreachable
                | Cause::OpenTimeout
                | Cause::ProxyRefused(_)
        ) || self
            .message
            .to_ascii_lowercase()
            .contains("connection refused")
    }
}

/// What the venue answered, shaped as the gem's Faraday stack shapes it (Task 3).
#[derive(Clone, Debug, PartialEq)]
pub enum Reply {
    /// A JSON body (any JSON value) under a JSON content type.
    Parsed(serde_json::Value),
    /// A body Faraday would not parse: another content type, or blank.
    NotJson,
    /// Faraday raised with an HTTP answer: 400–599, or an unparsable JSON body at any status.
    Status { status: u16, message: String },
}

mod connect;
mod io_timeout;
mod response;
pub use response::{decode, shape};

use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use hyper_util::rt::TokioIo;
use rustls::pki_types::ServerName;
use std::sync::Arc;
use std::time::Duration;

/// A single data frame: once handed to hyper, its next completed flush includes
/// the entire body. Empty requests still require a header write and flush.
struct RequestBody {
    inner: Full<Bytes>,
    progress: Arc<io_timeout::RequestProgress>,
}
impl hyper::body::Body for RequestBody {
    type Data = Bytes;
    type Error = std::convert::Infallible;
    fn poll_frame(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Option<Result<hyper::body::Frame<Bytes>, Self::Error>>> {
        let this = self.get_mut();
        let result = std::pin::Pin::new(&mut this.inner).poll_frame(cx);
        if result.is_ready() {
            this.progress.body_queued();
        }
        result
    }
    fn is_end_stream(&self) -> bool {
        self.inner.is_end_stream()
    }
    fn size_hint(&self) -> hyper::body::SizeHint {
        self.inner.size_hint()
    }
}

/// Honeymaker::Client::OPTIONS. Open bounds each connect phase; read and write bound each wait
/// on the socket, as Net::HTTP's timeouts do, never the whole exchange.
#[derive(Clone, Copy, Debug)]
pub struct Timeouts {
    pub open: Duration,
    pub read: Duration,
    pub write: Duration,
}
impl Default for Timeouts {
    fn default() -> Self {
        Self {
            open: Duration::from_secs(5),
            read: Duration::from_secs(30),
            write: Duration::from_secs(10),
        }
    }
}

#[derive(Debug)]
pub struct ConfigError(pub String);
impl std::fmt::Display for ConfigError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}
impl std::error::Error for ConfigError {}

pub struct Request {
    pub method: &'static str,
    pub path_and_query: String,
    pub headers: Vec<(String, String)>,
    pub body: Option<String>,
}

/// How Net::HTTP terminates the body read, which determines whether inflater finish errors escape.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BodyFraming {
    ContentLength,
    Chunked,
    CloseDelimited,
}

#[derive(Debug)]
pub struct Raw {
    pub status: u16,
    pub content_type: Option<String>,
    /// As received; Task 3 inflates gzip/deflate before shaping.
    pub content_encoding: Option<String>,
    /// Net::HTTP leaves a Content-Range body encoded.
    pub content_range: bool,
    pub framing: BodyFraming,
    pub body: Bytes,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Endpoint {
    pub tls: bool,
    pub host: String,
    pub port: u16,
}
impl Endpoint {
    /// host:port for CONNECT, and Host without the scheme's default port.
    pub fn authority(&self) -> String {
        let h = if self.host.contains(':') {
            format!("[{}]", self.host)
        } else {
            self.host.clone()
        };
        format!("{h}:{}", self.port)
    }
    fn host_header(&self) -> String {
        let default = if self.tls { 443 } else { 80 };
        if self.port == default {
            if self.host.contains(':') {
                format!("[{}]", self.host)
            } else {
                self.host.clone()
            }
        } else {
            self.authority()
        }
    }
}

#[derive(Clone, Debug)]
pub(crate) struct Proxy {
    pub host: String,
    pub port: u16,
    pub authorization: Option<String>,
}

pub struct Transport {
    pub(crate) base: String,
    pub(crate) target: Endpoint,
    pub(crate) server_name: ServerName<'static>,
    pub(crate) proxy: Option<Proxy>,
    pub(crate) timeouts: Timeouts,
    pub(crate) tls: Arc<rustls::ClientConfig>,
}

fn split_host_port(authority: &str, default: u16) -> Result<(String, u16), ConfigError> {
    let (host, port) = if let Some(rest) = authority.strip_prefix('[') {
        let (h, tail) = rest
            .split_once(']')
            .ok_or_else(|| ConfigError("unterminated IPv6 literal".into()))?;
        h.parse::<std::net::Ipv6Addr>()
            .map_err(|_| ConfigError("invalid IPv6 literal".into()))?;
        let port = if tail.is_empty() {
            None
        } else {
            Some(
                tail.strip_prefix(':')
                    .ok_or_else(|| ConfigError("invalid authority".into()))?,
            )
        };
        (h, port)
    } else {
        match authority.rsplit_once(':') {
            Some((h, p)) if !h.contains(':') => (h, Some(p)),
            Some(_) => return Err(ConfigError("IPv6 literals must be bracketed".into())),
            None => (authority, None),
        }
    };
    let port = match port {
        Some(p) => p.parse().map_err(|_| ConfigError("bad port".into()))?,
        None => default,
    };
    if host.is_empty() {
        return Err(ConfigError("missing host".into()));
    }
    ServerName::try_from(host.to_string()).map_err(|_| ConfigError("invalid host name".into()))?;
    Ok((host.to_string(), port))
}

fn endpoint(url: &str) -> Result<Endpoint, ConfigError> {
    let (tls, rest) = if let Some(r) = url.strip_prefix("https://") {
        (true, r)
    } else if let Some(r) = url.strip_prefix("http://") {
        (false, r)
    } else {
        return Err(ConfigError("base URL must be http:// or https://".into()));
    };
    let authority = rest.strip_suffix('/').unwrap_or(rest);
    if authority.contains(['/', '@', '?', '#']) {
        return Err(ConfigError("base URL must be scheme://host[:port]".into()));
    }
    let (host, port) = split_host_port(authority, if tls { 443 } else { 80 })?;
    Ok(Endpoint { tls, host, port })
}

/// Faraday/URI: userinfo is percent-decoded before it becomes Basic credentials.
fn unescape(s: &str) -> Vec<u8> {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        let hex = |c: u8| (c as char).to_digit(16);
        if b[i] == b'%'
            && i + 2 < b.len()
            && let (Some(h), Some(l)) = (hex(b[i + 1]), hex(b[i + 2]))
        {
            out.push((h * 16 + l) as u8);
            i += 3;
            continue;
        }
        out.push(b[i]);
        i += 1;
    }
    out
}

/// Ruling R5: http:// only, userinfo → Basic, never echo the URL (it may carry a password).
fn proxy(url: &str) -> Result<Proxy, ConfigError> {
    let rest = url
        .strip_prefix("http://")
        .ok_or_else(|| ConfigError("proxy must be an http:// URL".into()))?;
    let authority = rest.strip_suffix('/').unwrap_or(rest);
    if authority.contains(['/', '?', '#']) {
        return Err(ConfigError(
            "proxy URL must be http://[userinfo@]host[:port]".into(),
        ));
    }
    let (userinfo, hostport) = match authority.rsplit_once('@') {
        Some((u, h)) => (Some(u), h),
        None => (None, authority),
    };
    let (host, port) = split_host_port(hostport, 80)?;
    let authorization = userinfo.map(|u| {
        let (user, pass) = u.split_once(':').unwrap_or((u, ""));
        let mut creds = unescape(user);
        creds.push(b':');
        creds.extend(unescape(pass));
        use base64::Engine;
        format!(
            "Basic {}",
            base64::engine::general_purpose::STANDARD.encode(creds)
        )
    });
    Ok(Proxy {
        host,
        port,
        authorization,
    })
}

/// Ruling R4: rustls with ring, webpki roots unless the caller supplies a store (tests).
fn tls_config(
    roots: Option<Arc<rustls::RootCertStore>>,
) -> Result<Arc<rustls::ClientConfig>, ConfigError> {
    let roots = roots.unwrap_or_else(|| {
        Arc::new(rustls::RootCertStore {
            roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
        })
    });
    let cfg = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .map_err(|e| ConfigError(e.to_string()))?
    .with_root_certificates(roots)
    .with_no_client_auth();
    Ok(Arc::new(cfg))
}

impl Transport {
    pub fn new(
        base_url: &str,
        proxy_url: Option<&str>,
        timeouts: Timeouts,
        roots: Option<Arc<rustls::RootCertStore>>,
    ) -> Result<Self, ConfigError> {
        let target = endpoint(base_url)?;
        let server_name = ServerName::try_from(target.host.clone())
            .map_err(|_| ConfigError("invalid host name".into()))?;
        let proxy = proxy_url.map(proxy).transpose()?;
        let base = base_url.strip_suffix('/').unwrap_or(base_url).to_string();
        Ok(Self {
            base,
            target,
            server_name,
            proxy,
            timeouts,
            tls: tls_config(roots)?,
        })
    }

    pub fn url(&self, path_and_query: &str) -> String {
        format!("{}{path_and_query}", self.base)
    }

    /// Send, inflate, and shape a reply as the gem's Net::HTTP + Faraday stack does.
    pub async fn request(&self, req: &Request) -> Result<Reply, Failure> {
        let raw = decode(self.send(req).await?)?;
        Ok(shape(req.method, &self.url(&req.path_and_query), raw))
    }

    /// One request on its own connection (Ruling R3). Never retried.
    pub async fn send(&self, req: &Request) -> Result<Raw, Failure> {
        // Built before connecting: a header Ruby would refuse (a pasted key with a newline) fails
        // like legacy's client_error — ambiguous by Rails' rule, though nothing is sent.
        let mut b = hyper::Request::builder()
            .method(req.method)
            .uri(req.path_and_query.as_str())
            .header(hyper::header::HOST, self.target.host_header())
            .header(hyper::header::CONNECTION, "close")
            // What Net::HTTP adds to every request that sets neither Accept-Encoding nor Range.
            .header(
                hyper::header::ACCEPT_ENCODING,
                "gzip;q=1.0,deflate;q=0.6,identity;q=0.3",
            );
        for (k, v) in &req.headers {
            if k.eq_ignore_ascii_case("content-length")
                && v.trim().parse::<usize>().ok() != Some(req.body.as_ref().map_or(0, String::len))
            {
                return Err(Failure::new(
                    Cause::Other,
                    "ArgumentError: Content-Length does not match request body",
                ));
            }
            b = b.header(k.as_str(), v.as_str());
        }
        let progress = Arc::new(io_timeout::RequestProgress::default());
        let body = Bytes::from(req.body.clone().unwrap_or_default());
        if body.is_empty() {
            progress.body_queued();
        }
        let http_req = b
            .body(RequestBody {
                inner: Full::new(body),
                progress: progress.clone(),
            })
            .map_err(|e| Failure::new(Cause::Other, format!("ArgumentError: {e}")))?;

        // The read/write timeouts already sit under TLS, on the raw socket (Ruling R21).
        let io = connect::connect(self, progress).await?;
        let (mut sender, conn) = hyper::client::conn::http1::handshake(TokioIo::new(io))
            .await
            .map_err(|e| connect::hyper_failure(&e))?;
        let exchange = async move {
            let resp = sender.send_request(http_req).await?;
            let status = resp.status().as_u16();
            let header = |name: hyper::header::HeaderName| {
                resp.headers()
                    .get(name)
                    .and_then(|v| v.to_str().ok())
                    .map(str::to_string)
            };
            let content_type = header(hyper::header::CONTENT_TYPE);
            let content_encoding = header(hyper::header::CONTENT_ENCODING);
            let content_range = resp.headers().contains_key(hyper::header::CONTENT_RANGE);
            let chunked = resp
                .headers()
                .get_all(hyper::header::TRANSFER_ENCODING)
                .iter()
                .any(|v| {
                    v.to_str().is_ok_and(|v| {
                        v.split(',')
                            .any(|coding| coding.trim().eq_ignore_ascii_case("chunked"))
                    })
                });
            let framing = if chunked {
                BodyFraming::Chunked
            } else if resp.headers().contains_key(hyper::header::CONTENT_LENGTH) {
                BodyFraming::ContentLength
            } else {
                BodyFraming::CloseDelimited
            };
            let body = resp.into_body().collect().await?.to_bytes();
            Ok::<_, hyper::Error>(Raw {
                status,
                content_type,
                content_encoding,
                content_range,
                framing,
                body,
            })
        };
        // Driven together on this task: no spawn, so a current-thread runtime is enough.
        let (conn_result, result) = tokio::join!(conn, exchange);
        match (result, conn_result) {
            (Ok(raw), _) => Ok(raw),
            // The connection's error names the socket failure; the request's only says "closed".
            (Err(_), Err(conn_err)) => Err(connect::hyper_failure(&conn_err)),
            (Err(e), Ok(())) => Err(connect::hyper_failure(&e)),
        }
    }
}
