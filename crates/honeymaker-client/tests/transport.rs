mod support;
use honeymaker_client::transport::{Cause, Failure, Raw, Request, Timeouts, Transport};
use std::time::{Duration, Instant};
use support::*;

/// Distinct limits, so no test can race two of them.
fn quick() -> Timeouts {
    Timeouts {
        open: Duration::from_millis(300),
        read: Duration::from_millis(400),
        write: Duration::from_millis(500),
    }
}
fn post() -> Request {
    Request {
        method: "POST",
        path_and_query: "/0/private/AddOrder".into(),
        headers: vec![(
            "Content-Type".into(),
            "application/x-www-form-urlencoded".into(),
        )],
        body: Some("nonce=1&ordertype=market".into()),
    }
}
async fn send(base: &str, proxy: Option<&str>, pki: &Pki) -> Result<Raw, Failure> {
    Transport::new(base, proxy, quick(), Some(pki.roots.clone()))
        .unwrap()
        .send(&post())
        .await
}
fn err(r: &Result<Raw, Failure>) -> &Failure {
    r.as_ref().expect_err("expected a failure")
}

// ---- before the request: must be pre-transmission, and the target must have seen nothing ----

#[tokio::test(flavor = "current_thread")]
async fn a_refused_connection_is_pre_transmission() {
    let pki = pki();
    let port = closed_port().await;
    let r = send(&format!("https://127.0.0.1:{port}"), None, &pki).await;
    assert_eq!(
        err(&r),
        &Failure::new(
            Cause::Refused,
            format!("connection refused: 127.0.0.1:{port}")
        )
    );
    assert!(err(&r).pre_transmission());
}

#[tokio::test(flavor = "current_thread")]
async fn a_tls_handshake_that_stalls_is_an_open_timeout() {
    let pki = pki();
    let t = target(Tls::NeverHandshake, Act::Hang, &pki).await;
    let r = send(&t.https(), None, &pki).await;
    assert_eq!(
        err(&r),
        &Failure::new(Cause::OpenTimeout, "Net::OpenTimeout")
    );
    assert!(err(&r).pre_transmission());
    assert_eq!(t.seen.request_bytes(), 0);
}

#[tokio::test(flavor = "current_thread")]
async fn a_peer_that_does_not_speak_tls_is_a_tls_failure_and_rails_calls_it_ambiguous() {
    let pki = pki();
    let t = target(Tls::NotTls, Act::Hang, &pki).await;
    let r = send(&t.https(), None, &pki).await;
    assert_eq!(err(&r).cause, Cause::Tls);
    assert!(
        !err(&r).pre_transmission(),
        "Ruling R1: OpenSSL::SSL::SSLError is not pre-transmission"
    );
}

#[tokio::test(flavor = "current_thread")]
async fn an_untrusted_certificate_is_a_tls_failure_that_sent_nothing() {
    let pki = pki();
    let t = target(Tls::Untrusted, Act::Hang, &pki).await;
    let r = send(&t.https(), None, &pki).await;
    assert_eq!(err(&r).cause, Cause::Tls);
    assert!(!err(&r).pre_transmission());
    assert_eq!(
        t.seen.request_bytes(),
        0,
        "a handshake failure never writes the request"
    );
}

#[tokio::test(flavor = "current_thread")]
async fn a_localhost_url_reaches_an_ipv4_only_listener() {
    let pki = pki();
    let t = target(
        Tls::Trusted,
        Act::Reply(http("200 OK", "application/json", OK_JSON)),
        &pki,
    )
    .await;
    assert_eq!(t.addr.ip(), std::net::Ipv4Addr::LOCALHOST);
    let raw = send(&t.https_localhost(), None, &pki).await.unwrap();
    assert_eq!(raw.status, 200);
    assert_eq!(raw.body.as_ref(), OK_JSON.as_bytes());
    assert_eq!(t.seen.conns(), 1);
    assert_eq!(t.seen.heads().len(), 1);
}

// ---- the exchange ----

#[tokio::test(flavor = "current_thread")]
async fn an_answer_over_tls_comes_back_raw_with_one_connection_and_connection_close() {
    let pki = pki();
    let t = target(
        Tls::Trusted,
        Act::Reply(http("200 OK", "application/json", OK_JSON)),
        &pki,
    )
    .await;
    let raw = send(&t.https(), None, &pki).await.unwrap();
    assert_eq!(
        (raw.status, raw.content_type.as_deref(), &raw.body[..]),
        (200, Some("application/json"), OK_JSON.as_bytes())
    );
    let head = &t.seen.heads()[0];
    assert!(
        head.starts_with("post /0/private/addorder http/1.1\r\n"),
        "{head}"
    );
    assert!(head.contains(&format!("host: 127.0.0.1:{}\r\n", t.addr.port())));
    assert!(head.contains("connection: close\r\n"));
    assert!(
        head.contains("accept-encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3\r\n"),
        "the gem's header"
    );
    assert!(head.ends_with("nonce=1&ordertype=market"));
    assert_eq!(t.seen.conns(), 1);
}

#[tokio::test(flavor = "current_thread")]
async fn a_silent_venue_after_the_request_is_a_read_timeout_and_ambiguous() {
    let pki = pki();
    let t = target(Tls::Trusted, Act::Hang, &pki).await;
    let r = send(&t.https(), None, &pki).await;
    assert_eq!(
        err(&r),
        &Failure::new(Cause::ReadTimeout, "Net::ReadTimeout")
    );
    assert!(!err(&r).pre_transmission());
    assert!(t.seen.request_bytes() > 0);
}

#[tokio::test(flavor = "current_thread")]
async fn a_slow_but_steady_answer_is_not_a_timeout() {
    let pki = pki();
    // 4 pieces, 130 ms apart: each wait is a third of the 400 ms read limit, the total is not.
    let t = target(
        Tls::Trusted,
        Act::Trickle(http("200 OK", "application/json", OK_JSON), 130),
        &pki,
    )
    .await;
    assert_eq!(send(&t.https(), None, &pki).await.unwrap().status, 200);
}

#[tokio::test(flavor = "current_thread")]
async fn a_close_after_the_request_is_end_of_file_ambiguous_and_never_retried() {
    let pki = pki();
    let t = target(Tls::Plain, Act::Close, &pki).await;
    let r = send(&t.http(), None, &pki).await;
    assert_eq!(err(&r), &Failure::new(Cause::Eof, "end of file reached"));
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(t.seen.conns(), 1, "no second attempt");
}

#[tokio::test(flavor = "current_thread")]
async fn post_send_failures_are_never_pre_transmission() {
    let pki = pki();
    for (tls, act) in [
        (Tls::Trusted, Act::Close),
        (Tls::Plain, Act::Reset),
        (Tls::Trusted, Act::Reset),
        (Tls::Trusted, Act::Partial),
    ] {
        let t = target(tls, act, &pki).await;
        let base = if matches!(tls, Tls::Plain) {
            t.http()
        } else {
            t.https()
        };
        let r = send(&base, None, &pki).await;
        assert!(!err(&r).pre_transmission(), "{:?}", err(&r));
        assert!(t.seen.request_bytes() > 0);
        assert_eq!(t.seen.conns(), 1);
    }
}

// ---- the proxy ----

#[tokio::test(flavor = "current_thread")]
async fn a_refused_proxy_is_pre_transmission_and_names_the_proxy() {
    let port = closed_port().await;
    let r = send(
        "https://api.kraken.com",
        Some(&format!("http://127.0.0.1:{port}")),
        &pki(),
    )
    .await;
    assert_eq!(
        err(&r),
        &Failure::new(
            Cause::Refused,
            format!("connection refused: 127.0.0.1:{port}")
        )
    );
}

#[tokio::test(flavor = "current_thread")]
async fn a_proxy_refusing_connect_with_4xx_is_pre_transmission() {
    let p = proxy(ProxyAct::Answer(
        "HTTP/1.1 403 Filtered\r\nContent-Length: 0\r\n\r\n",
    ))
    .await;
    let r = send(
        "https://api.kraken.com",
        Some(&format!("http://127.0.0.1:{}", p.addr.port())),
        &pki(),
    )
    .await;
    assert_eq!(
        err(&r),
        &Failure::new(Cause::ProxyRefused(403), "403 \"Filtered\"")
    );
    assert!(err(&r).pre_transmission());
    assert!(p.seen.heads()[0].starts_with("connect api.kraken.com:443 http/1.1\r\n"));
}

#[tokio::test(flavor = "current_thread")]
async fn proxy_credentials_go_as_basic_auth_on_connect() {
    let p = proxy(ProxyAct::Answer(
        "HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n",
    ))
    .await;
    let r = send(
        "https://api.kraken.com",
        Some(&format!("http://user:p%40ss@127.0.0.1:{}/", p.addr.port())),
        &pki(),
    )
    .await;
    assert_eq!(err(&r).cause, Cause::ProxyRefused(407));
    assert!(
        p.seen.heads()[0].contains("proxy-authorization: basic dxnlcjpwqhnz\r\n"),
        "{}",
        p.seen.heads()[0]
    ); // user:p@ss, lowercased
}

#[tokio::test(flavor = "current_thread")]
async fn a_proxy_failing_connect_with_5xx_or_closing_is_ambiguous_as_rails_says() {
    for (act, want) in [
        (
            ProxyAct::Answer(
                "HTTP/1.1 500 Unable to connect\r\nContent-Type: text/html\r\nContent-Length: 5\r\n\r\nnope!",
            ),
            Failure::new(Cause::ProxyFailed, "500 \"Unable to connect\""),
        ),
        (
            ProxyAct::Close,
            Failure::new(Cause::Eof, "end of file reached"),
        ),
    ] {
        let p = proxy(act).await;
        let r = send(
            "https://api.kraken.com",
            Some(&format!("http://127.0.0.1:{}", p.addr.port())),
            &pki(),
        )
        .await;
        assert_eq!(err(&r), &want);
        assert!(!err(&r).pre_transmission());
    }
}

#[tokio::test(flavor = "current_thread")]
async fn a_proxy_that_never_answers_connect_is_an_open_timeout_not_a_hang() {
    let p = proxy(ProxyAct::Hang).await;
    let started = Instant::now();
    let r = send(
        "https://api.kraken.com",
        Some(&format!("http://127.0.0.1:{}", p.addr.port())),
        &pki(),
    )
    .await;
    assert_eq!(
        err(&r),
        &Failure::new(Cause::OpenTimeout, "Net::OpenTimeout (proxy CONNECT)")
    );
    assert!(err(&r).pre_transmission(), "Ruling R2");
    assert!(started.elapsed() < Duration::from_secs(2));
}

#[tokio::test(flavor = "current_thread")]
async fn a_tunnel_carries_tls_end_to_end() {
    let pki = pki();
    let t = target(
        Tls::Trusted,
        Act::Reply(http("200 OK", "application/json", OK_JSON)),
        &pki,
    )
    .await;
    let p = proxy(ProxyAct::Tunnel(t.addr)).await;
    let raw = send(
        &t.https_localhost(),
        Some(&format!("http://127.0.0.1:{}", p.addr.port())),
        &pki,
    )
    .await
    .unwrap();
    assert_eq!(raw.status, 200);
    assert!(
        p.seen.heads()[0].starts_with(&format!("connect localhost:{} http/1.1\r\n", t.addr.port()))
    );
    assert_eq!(t.seen.heads().len(), 1);
}

#[tokio::test(flavor = "current_thread")]
async fn a_silent_venue_behind_a_tunnel_is_a_read_timeout() {
    let pki = pki();
    let t = target(Tls::Trusted, Act::Hang, &pki).await;
    let p = proxy(ProxyAct::Tunnel(t.addr)).await;
    let r = send(
        &t.https_localhost(),
        Some(&format!("http://127.0.0.1:{}", p.addr.port())),
        &pki,
    )
    .await;
    assert_eq!(err(&r).cause, Cause::ReadTimeout);
}

// ---- timeouts measure socket waits under TLS (Ruling R21) ----

fn with(open: u64, read: u64, write: u64) -> Timeouts {
    Timeouts {
        open: Duration::from_millis(open),
        read: Duration::from_millis(read),
        write: Duration::from_millis(write),
    }
}

#[tokio::test(flavor = "current_thread")]
async fn fragmented_tls_records_that_keep_arriving_are_not_a_timeout() {
    let pki = pki();
    let body = format!(
        r#"{{"error":[],"result":{{"pad":"{}"}}}}"#,
        "x".repeat(4000)
    );
    // One ~4 KB record in 512-byte pieces, 100 ms apart: each socket wait is a quarter of the
    // 400 ms read limit, while the record takes about 800 ms to complete.
    let t = target(
        Tls::Relayed(Relay::Trickle {
            chunk: 512,
            ms: 100,
        }),
        Act::Reply(http("200 OK", "application/json", &body)),
        &pki,
    )
    .await;
    let tr = Transport::new(
        &t.https(),
        None,
        with(5000, 400, 1000),
        Some(pki.roots.clone()),
    )
    .unwrap();
    let started = Instant::now();
    let raw = tr.send(&post()).await.unwrap();
    assert_eq!((raw.status, raw.body.len()), (200, body.len()));
    assert!(
        started.elapsed() > Duration::from_millis(400),
        "the reply really outlasted the read limit"
    );
}

#[tokio::test(flavor = "current_thread")]
async fn a_stall_inside_a_tls_record_is_a_read_timeout() {
    let pki = pki();
    let t = target(
        Tls::Relayed(Relay::StallAfter(20)),
        Act::Reply(http("200 OK", "application/json", OK_JSON)),
        &pki,
    )
    .await;
    let r = Transport::new(
        &t.https(),
        None,
        with(5000, 400, 1000),
        Some(pki.roots.clone()),
    )
    .unwrap()
    .send(&post())
    .await;
    assert_eq!(
        err(&r),
        &Failure::new(Cause::ReadTimeout, "Net::ReadTimeout")
    );
    assert!(!err(&r).pre_transmission());
}

#[tokio::test(flavor = "current_thread")]
async fn a_progressing_upload_longer_than_the_read_limit_is_not_a_timeout() {
    let pki = pki();
    // The double's raw socket takes the first 1 MiB 64 KiB per 100 ms (about 1.6 s of steady
    // progress, four times the 400 ms read limit), then drains the rest at full speed; the server
    // answers as soon as the request is complete.
    let relay = Relay::ThrottleUpload {
        chunk: 64 << 10,
        ms: 100,
        budget: 1 << 20,
    };
    let t = target(
        Tls::Relayed(relay),
        Act::Reply(http("200 OK", "application/json", OK_JSON)),
        &pki,
    )
    .await;
    let big = Request {
        body: Some("x".repeat(16 << 20)),
        ..post()
    };
    let raw = Transport::new(
        &t.https(),
        None,
        with(5000, 400, 2000),
        Some(pki.roots.clone()),
    )
    .unwrap()
    .send(&big)
    .await
    .unwrap();
    assert_eq!(raw.status, 200);
    let times = t.seen.times();
    let transmission = times.request_done.unwrap() - times.first_byte.unwrap();
    let latency = times.replied.unwrap() - times.request_done.unwrap();
    assert!(
        transmission > Duration::from_millis(400),
        "{transmission:?}: the upload outlasted the read limit"
    );
    assert!(
        latency < Duration::from_millis(100),
        "{latency:?}: the reply was prompt"
    );
}

#[tokio::test(flavor = "current_thread")]
async fn a_blocked_tls_write_is_a_write_timeout_sent_once() {
    let pki = pki();
    let t = target(Tls::Trusted, Act::ReadSomeThenStop(1024), &pki).await;
    let big = Request {
        body: Some("x".repeat(32 << 20)),
        ..post()
    };
    // Distinct limits: a 5 s read limit cannot race the 300 ms write limit.
    let r = Transport::new(
        &t.https(),
        None,
        with(5000, 5000, 300),
        Some(pki.roots.clone()),
    )
    .unwrap()
    .send(&big)
    .await;
    assert_eq!(
        err(&r),
        &Failure::new(Cause::WriteTimeout, "Net::WriteTimeout")
    );
    assert!(!err(&r).pre_transmission());
    assert!(
        t.seen.request_bytes() >= 1024,
        "part of the request reached the venue"
    );
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(t.seen.conns(), 1, "never retried");
}

// ---- configuration ----

#[test]
fn a_bad_proxy_or_base_url_is_a_configuration_error_that_never_echoes_credentials() {
    for proxy in [
        "",
        "socks5://h:1",
        "https://h:1",
        "http://user:secret@h:notaport",
    ] {
        let e = Transport::new(
            "https://api.kraken.com",
            Some(proxy),
            Timeouts::default(),
            None,
        )
        .err()
        .unwrap();
        assert!(!e.to_string().contains("secret"), "{e}");
    }
    assert!(Transport::new("ftp://api.kraken.com", None, Timeouts::default(), None).is_err());
    assert!(
        Transport::new(
            "https://api.kraken.com/0/public",
            None,
            Timeouts::default(),
            None
        )
        .is_err()
    );
}

#[test]
fn the_defaults_are_the_gems() {
    let t = Timeouts::default();
    assert_eq!(
        (t.open, t.read, t.write),
        (
            Duration::from_secs(5),
            Duration::from_secs(30),
            Duration::from_secs(10)
        )
    );
}

#[tokio::test(flavor = "current_thread")]
async fn malformed_connect_statuses_never_establish_a_tunnel() {
    for response in [
        "garbage 200 OK\r\n\r\n",
        "HTTP/1.1 0200 OK\r\n\r\n",
        "HTTP/1.1 200\r\nbroken\r\n\r\n",
    ] {
        let p = proxy(ProxyAct::Answer(response)).await;
        let result = send("https://localhost", Some(&p.http()), &pki()).await;
        assert_eq!(err(&result).cause, Cause::ProxyFailed);
        assert!(!err(&result).pre_transmission());
        assert_eq!(p.seen.conns(), 1);
    }
}

#[test]
fn malformed_authorities_are_rejected_without_echoing_credentials() {
    for base in ["https://[::1]suffix", "https://::1", "https://[localhost]"] {
        assert!(Transport::new(base, None, quick(), None).is_err(), "{base}");
    }
    for proxy in [
        "http://user:secret@host/path",
        "http://host?query",
        "http://host#fragment",
        "http://[::1]suffix",
    ] {
        let failure = Transport::new("https://localhost", Some(proxy), quick(), None)
            .err()
            .expect("invalid proxy");
        assert!(!failure.to_string().contains("secret"));
    }
}

#[tokio::test(flavor = "current_thread")]
async fn raw_metadata_and_encoded_body_are_preserved() {
    let pki = pki();
    let t = target(Tls::Trusted, Act::Reply("HTTP/1.1 206 Partial Content\r\nContent-Encoding: gzip\r\nContent-Range: bytes 0-3/4\r\nContent-Length: 4\r\n\r\nraw!"), &pki).await;
    let raw = send(&t.https(), None, &pki).await.unwrap();
    assert_eq!(raw.status, 206);
    assert_eq!(raw.content_type, None);
    assert_eq!(raw.content_encoding.as_deref(), Some("gzip"));
    assert!(raw.content_range);
    assert_eq!(&raw.body[..], b"raw!");
}

#[tokio::test(flavor = "current_thread")]
async fn an_empty_request_still_enables_the_response_timeout() {
    let pki = pki();
    let t = target(Tls::Trusted, Act::Hang, &pki).await;
    let req = Request {
        method: "GET",
        body: None,
        ..post()
    };
    let result = Transport::new(&t.https(), None, quick(), Some(pki.roots.clone()))
        .unwrap()
        .send(&req)
        .await;
    assert_eq!(err(&result).cause, Cause::ReadTimeout);
    assert!(!err(&result).pre_transmission());
    assert_eq!(t.seen.conns(), 1);
}

#[tokio::test(flavor = "current_thread")]
async fn an_inconsistent_content_length_is_rejected_before_connecting() {
    let pki = pki();
    let t = target(Tls::Trusted, Act::Hang, &pki).await;
    let mut req = post();
    req.headers.push(("Content-Length".into(), "0".into()));
    let tr = Transport::new(&t.https(), None, quick(), Some(pki.roots.clone())).unwrap();
    let result = tokio::time::timeout(Duration::from_secs(1), tr.send(&req))
        .await
        .expect("must not hang with the response timer disabled");
    assert_eq!(err(&result).cause, Cause::Other);
    assert_eq!(t.seen.conns(), 0);
}

#[tokio::test(flavor = "current_thread")]
async fn request_shapes_what_send_received() {
    use honeymaker_client::transport::Reply;
    let pki = pki();
    let t = target(
        Tls::Trusted,
        Act::Reply(http("200 OK", "application/json", OK_JSON)),
        &pki,
    )
    .await;
    let tr = Transport::new(&t.https(), None, quick(), Some(pki.roots.clone())).unwrap();
    assert_eq!(
        tr.request(&post()).await.unwrap(),
        Reply::Parsed(serde_json::json!({"error": [], "result": {"a": 1}}))
    );
}

// Binary replies exercise framing and inflation through the real send/request pipeline.
async fn encoded_response(
    framing: honeymaker_client::transport::BodyFraming,
    truncated: bool,
) -> Transport {
    use flate2::{Compression, write::GzEncoder};
    use honeymaker_client::transport::BodyFraming;
    use std::io::Write;
    let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
    encoder.write_all(OK_JSON.as_bytes()).unwrap();
    let mut body = encoder.finish().unwrap();
    if truncated {
        body.truncate(12);
    }
    let mut wire = b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\nConnection: close\r\n".to_vec();
    match framing {
        BodyFraming::ContentLength => {
            wire.extend(format!("Content-Length: {}\r\n\r\n", body.len()).as_bytes())
        }
        BodyFraming::Chunked => wire
            .extend(format!("Transfer-Encoding: chunked\r\n\r\n{:x}\r\n", body.len()).as_bytes()),
        BodyFraming::CloseDelimited => wire.extend(b"\r\n"),
    }
    wire.extend(body);
    if framing == BodyFraming::Chunked {
        wire.extend(b"\r\n0\r\n\r\n");
    }
    wire_response(wire).await
}

async fn wire_response(wire: Vec<u8>) -> Transport {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut request = vec![0; post().body.unwrap().len()];
        let mut head = Vec::new();
        while !head.ends_with(b"\r\n\r\n") {
            head.push(socket.read_u8().await.unwrap());
        }
        socket.read_exact(&mut request).await.unwrap();
        socket.write_all(&wire).await.unwrap();
        socket.shutdown().await.unwrap();
    });
    Transport::new(&base, None, quick(), None).unwrap()
}

#[tokio::test(flavor = "current_thread")]
async fn send_preserves_body_framing() {
    use honeymaker_client::transport::BodyFraming;
    for framing in [
        BodyFraming::ContentLength,
        BodyFraming::Chunked,
        BodyFraming::CloseDelimited,
    ] {
        let tr = encoded_response(framing, true).await;
        let raw = tr.send(&post()).await.unwrap();
        assert_eq!(raw.framing, framing);
        assert_eq!(raw.body.len(), 12);
        assert_eq!(raw.content_encoding.as_deref(), Some("gzip"));
    }
}

#[tokio::test(flavor = "current_thread")]
async fn request_inflates_gzip_under_every_framing() {
    use honeymaker_client::transport::{BodyFraming, Reply};
    for framing in [
        BodyFraming::ContentLength,
        BodyFraming::Chunked,
        BodyFraming::CloseDelimited,
    ] {
        let tr = encoded_response(framing, false).await;
        assert_eq!(
            tr.request(&post()).await.unwrap(),
            Reply::Parsed(serde_json::json!({"error": [], "result": {"a": 1}}))
        );
    }
}

#[tokio::test(flavor = "current_thread")]
async fn request_with_truncated_content_length_gzip_matches_the_gem() {
    use honeymaker_client::transport::{BodyFraming, Reply};
    let tr = encoded_response(BodyFraming::ContentLength, true).await;
    assert_eq!(tr.request(&post()).await.unwrap(), Reply::NotJson);
}

#[tokio::test(flavor = "current_thread")]
async fn request_with_truncated_chunked_gzip_matches_the_gem() {
    use honeymaker_client::transport::{BodyFraming, Reply};
    let tr = encoded_response(BodyFraming::Chunked, true).await;
    assert_eq!(tr.request(&post()).await.unwrap(), Reply::NotJson);
}

#[tokio::test(flavor = "current_thread")]
async fn request_with_truncated_close_delimited_gzip_matches_the_gem() {
    use honeymaker_client::transport::BodyFraming;
    let tr = encoded_response(BodyFraming::CloseDelimited, true).await;
    let f = tr.request(&post()).await.unwrap_err();
    assert_eq!(f.cause, Cause::Other);
    assert!(f.message.starts_with("Zlib::BufError:"));
    assert!(!f.pre_transmission());
}

#[tokio::test(flavor = "current_thread")]
async fn a_non_chunked_transfer_encoding_is_close_delimited() {
    use honeymaker_client::transport::BodyFraming;
    let pki = pki();
    let t = target(
        Tls::Plain,
        Act::Reply(
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: identity\r\nConnection: close\r\n\r\nraw!",
        ),
        &pki,
    )
    .await;
    let raw = send(&t.http(), None, &pki).await.unwrap();
    assert_eq!(raw.framing, BodyFraming::CloseDelimited);
    assert_eq!(&raw.body[..], b"raw!");
}

async fn header_response(headers: &[u8], body: &[u8]) -> Transport {
    let mut wire = format!(
        "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: {}\r\n",
        body.len()
    )
    .into_bytes();
    wire.extend(headers);
    wire.extend(b"\r\n");
    wire.extend(body);
    wire_response(wire).await
}

#[tokio::test(flavor = "current_thread")]
async fn repeated_gzip_headers_leave_the_body_encoded_and_fail_json_parsing() {
    use flate2::{Compression, write::GzEncoder};
    use honeymaker_client::transport::{Reply, decode};
    use std::io::Write;
    let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
    encoder.write_all(OK_JSON.as_bytes()).unwrap();
    let body = encoder.finish().unwrap();
    let headers =
        b"Content-Type: application/json\r\nContent-Encoding: gzip\r\nContent-Encoding: gzip\r\n";
    let raw = header_response(headers, &body)
        .await
        .send(&post())
        .await
        .unwrap();
    assert_eq!(raw.content_encoding.as_deref(), Some("gzip, gzip"));
    assert_eq!(&decode(raw).unwrap().body[..], body);
    assert_eq!(
        header_response(headers, &body)
            .await
            .request(&post())
            .await
            .unwrap(),
        Reply::Status {
            status: 200,
            message: String::from_utf8_lossy(&body).into_owned()
        }
    );
}

#[tokio::test(flavor = "current_thread")]
async fn repeated_content_types_are_joined_before_matching_json() {
    use honeymaker_client::transport::Reply;
    let headers = b"Content-Type: text/plain\r\nContent-Type: application/json\r\n";
    let raw = header_response(headers, OK_JSON.as_bytes())
        .await
        .send(&post())
        .await
        .unwrap();
    assert_eq!(
        raw.content_type.as_deref(),
        Some("text/plain, application/json")
    );
    assert_eq!(
        header_response(headers, OK_JSON.as_bytes())
            .await
            .request(&post())
            .await
            .unwrap(),
        Reply::Parsed(serde_json::json!({"error": [], "result": {"a": 1}}))
    );
}

#[tokio::test(flavor = "current_thread")]
async fn non_ascii_header_values_are_retained_with_lossy_decoding() {
    use honeymaker_client::transport::Reply;
    let headers = b"Content-Type: application/\xff+json\r\nContent-Encoding: \xfe\r\n";
    let raw = header_response(headers, OK_JSON.as_bytes())
        .await
        .send(&post())
        .await
        .unwrap();
    assert_eq!(raw.content_type.as_deref(), Some("application/�+json"));
    assert_eq!(raw.content_encoding.as_deref(), Some("�"));
    assert_eq!(
        header_response(headers, OK_JSON.as_bytes())
            .await
            .request(&post())
            .await
            .unwrap(),
        Reply::Parsed(serde_json::json!({"error": [], "result": {"a": 1}}))
    );
}
