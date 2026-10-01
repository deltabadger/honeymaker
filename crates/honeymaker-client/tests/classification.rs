//! Spec §4's legacy transport modes, each with the class deltabadger's Rails code gives the chain
//! the row records: Exchange#ambiguous_placement_error? → Client.most_specific_cause →
//! Client.pre_transmission? (PRE_TRANSMISSION_ERRORS, or /connection refused/i in the text).
use honeymaker_client::kraken::{VenueError, outcome};
use honeymaker_client::transport::{Cause, Failure, Reply};
use serde_json::json;

fn fail(cause: Cause, message: &str) -> Result<Reply, Failure> {
    Err(Failure::new(cause, message))
}
fn status(status: u16, message: &str) -> Result<Reply, Failure> {
    Ok(Reply::Status { status, message: message.into() })
}
fn class(r: Result<Reply, Failure>) -> &'static str {
    match outcome(r) {
        Ok(_) => "ok",
        Err(VenueError::Rejected(_)) => "rejected",
        Err(VenueError::Ambiguous(_)) => "ambiguous",
        Err(VenueError::Transient(_)) => "transient",
    }
}

#[test]
fn every_legacy_transport_mode_gets_the_class_rails_gives_it() {
    let rows = vec![
        // [ConnectionFailed, Net::HTTP::Persistent::Error, Errno::ECONNREFUSED] → ECONNREFUSED ∈ PRE
        ("refused", fail(Cause::Refused, "connection refused: 127.0.0.1:9"), "transient"),
        // [ConnectionFailed, Socket::ResolutionError] ∈ PRE
        ("dns", fail(Cause::Dns, "Failed to open TCP connection to x.invalid:443 (getaddrinfo)"), "transient"),
        // [TimeoutError, Net::OpenTimeout, IO::TimeoutError] → Net::OpenTimeout (tier 1) ∈ PRE
        ("tcp connect timeout", fail(Cause::OpenTimeout, "Failed to open TCP connection to 10.255.255.1:81 (user specified timeout for 10.255.255.1:81)"), "transient"),
        ("tls handshake stall", fail(Cause::OpenTimeout, "Net::OpenTimeout"), "transient"),
        // EHOSTUNREACH / ENETUNREACH / ENETDOWN / EADDRNOTAVAIL ∈ PRE
        ("unreachable", fail(Cause::Unreachable, "Failed to open TCP connection to 10.0.0.1:443 (No route to host)"), "transient"),
        // [SSLError, OpenSSL::SSL::SSLError] → tier 4, NOT in PRE (Ruling R1)
        ("tls not-tls / untrusted", fail(Cause::Tls, "SSL_connect: invalid peer certificate: UnknownIssuer"), "ambiguous"),
        // [TimeoutError, Net::ReadTimeout] → tier 1, not in PRE
        ("read timeout", fail(Cause::ReadTimeout, "Net::ReadTimeout"), "ambiguous"),
        ("write timeout", fail(Cause::WriteTimeout, "Net::WriteTimeout"), "ambiguous"),
        // [ConnectionFailed, EOFError]
        ("eof after request", fail(Cause::Eof, "end of file reached"), "ambiguous"),
        ("abrupt tls close", fail(Cause::Tls, "SSL_read: unexpected eof while reading"), "ambiguous"),
        // [ConnectionFailed, Errno::ECONNRESET] → tier 2, not in PRE
        ("rst after request", fail(Cause::Reset, "Connection reset by peer"), "ambiguous"),
        ("proxy refused", fail(Cause::Refused, "connection refused: 127.0.0.1:8100"), "transient"),
        // Ruling R2: a bounded CONNECT is an open-phase timeout, as Net::OpenTimeout
        ("proxy CONNECT stall", fail(Cause::OpenTimeout, "Net::OpenTimeout (proxy CONNECT)"), "transient"),
        ("proxy CONNECT eof", fail(Cause::Eof, "end of file reached"), "ambiguous"),
        // [ConnectionFailed, Net::HTTPClientException] ∈ PRE
        ("proxy CONNECT 403", fail(Cause::ProxyRefused(403), "403 \"Filtered\""), "transient"),
        ("proxy CONNECT 407", fail(Cause::ProxyRefused(407), "407 \"Proxy Authentication Required\""), "transient"),
        // [ConnectionFailed, Net::HTTPFatalError] → falls back to Faraday::ConnectionFailed (Ruling R1)
        ("proxy CONNECT 500", fail(Cause::ProxyFailed, "500 \"Unable to connect\""), "ambiguous"),
        // …unless the text says the connection was refused
        ("proxy CONNECT 502 refused", fail(Cause::ProxyFailed, "502 \"Connection refused\""), "transient"),
        ("other errno on connect", fail(Cause::Other, "Failed to open TCP connection to h:1 (Permission denied)"), "ambiguous"),
        ("http 500", status(500, r#"{"error":["EService:Unavailable"]}"#), "ambiguous"),
        ("http 500 empty", status(500, "the server responded with status 500 for POST https://api.kraken.com/0/private/AddOrder"), "ambiguous"),
        ("http 404 html", status(404, "<h1>nf</h1> é"), "rejected"),
        ("http 429", status(429, "no"), "rejected"),
        ("http 302 unparsable json", status(302, "{"), "rejected"),
        ("200 invalid json", status(200, "{not json"), "ambiguous"),
        ("200 html or blank", Ok(Reply::NotJson), "ambiguous"),
        ("200 top-level array", Ok(Reply::Parsed(json!([1, 2.5, "x"]))), "ambiguous"),
        ("200 null", Ok(Reply::Parsed(json!(null))), "ambiguous"),
        ("200 object", Ok(Reply::Parsed(json!({"error": [], "result": {}}))), "ok"),
    ];
    for (name, reply, want) in rows {
        assert_eq!(class(reply), want, "{name}");
    }
}

#[test]
fn messages_travel_verbatim() {
    assert_eq!(
        outcome(status(404, "<h1>nf</h1> é")),
        Err(VenueError::Rejected(vec!["<h1>nf</h1> é".into()]))
    );
    assert_eq!(
        outcome(fail(Cause::Refused, "connection refused: h:1")),
        Err(VenueError::Transient("connection refused: h:1".into()))
    );
    assert_eq!(
        outcome(Ok(Reply::NotJson)),
        Err(VenueError::Ambiguous("Kraken: unreadable response".into()))
    );
}
