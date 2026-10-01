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
        Self { cause, message: message.into() }
    }

    /// Client.pre_transmission?: the cause is one Client::PRE_TRANSMISSION_ERRORS names, or the
    /// text says the connection was refused. Only then did the request provably never leave.
    pub fn pre_transmission(&self) -> bool {
        matches!(
            self.cause,
            Cause::Dns | Cause::Refused | Cause::Unreachable | Cause::OpenTimeout | Cause::ProxyRefused(_)
        ) || self.message.to_ascii_lowercase().contains("connection refused")
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
