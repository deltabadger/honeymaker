//! Faraday 2.14 with `request :json`, `response :json` (content_type /\bjson$/),
//! `response :raise_error`, rescued by Honeymaker::Client#with_rescue (spec §4 rows).
use bytes::Bytes;
use flate2::Compression;
use flate2::write::{GzEncoder, ZlibEncoder};
use honeymaker_client::transport::{BodyFraming, Cause, Raw, Reply, decode, shape};
use serde_json::json;
use std::io::Write;

const URL: &str = "https://api.kraken.com/0/private/AddOrder";
fn raw(status: u16, ct: Option<&str>, enc: Option<&str>, body: Vec<u8>) -> Raw {
    Raw {
        status,
        content_type: ct.map(str::to_string),
        content_encoding: enc.map(str::to_string),
        content_range: false,
        framing: BodyFraming::ContentLength,
        body: Bytes::from(body),
    }
}
fn reply(status: u16, ct: Option<&str>, body: &str) -> Reply {
    shape("POST", URL, raw(status, ct, None, body.as_bytes().to_vec()))
}
fn gzip(b: &[u8]) -> Vec<u8> {
    let mut e = GzEncoder::new(Vec::new(), Compression::default());
    e.write_all(b).unwrap();
    e.finish().unwrap()
}
fn zlib(b: &[u8]) -> Vec<u8> {
    let mut e = ZlibEncoder::new(Vec::new(), Compression::default());
    e.write_all(b).unwrap();
    e.finish().unwrap()
}
fn decoded(r: Raw) -> Reply {
    shape("POST", URL, decode(r).unwrap())
}

#[test]
fn gzip_and_deflate_bodies_are_inflated_at_any_status_as_net_http_does() {
    let ok = br#"{"error":[],"result":{"txid":["OTX-1"]}}"#;
    for enc in ["gzip", "x-gzip", "GZIP"] {
        assert_eq!(
            decoded(raw(200, Some("application/json"), Some(enc), gzip(ok))),
            Reply::Parsed(json!({"error": [], "result": {"txid": ["OTX-1"]}})),
            "{enc}"
        );
    }
    // "deflate" is zlib-wrapped; Zlib::Inflate.new(32 + MAX_WBITS) also accepts a gzip stream there.
    assert_eq!(
        decoded(raw(
            200,
            Some("application/json"),
            Some("deflate"),
            zlib(ok)
        )),
        Reply::Parsed(json!({"error": [], "result": {"txid": ["OTX-1"]}}))
    );
    assert_eq!(
        decoded(raw(
            200,
            Some("application/json"),
            Some("deflate"),
            gzip(ok)
        )),
        Reply::Parsed(json!({"error": [], "result": {"txid": ["OTX-1"]}}))
    );
    let refusal = br#"{"error":["EOrder:Insufficient funds"]}"#;
    assert_eq!(
        decoded(raw(
            400,
            Some("application/json"),
            Some("gzip"),
            gzip(refusal)
        )),
        st(400, r#"{"error":["EOrder:Insufficient funds"]}"#)
    );
    assert_eq!(
        decoded(raw(200, Some("application/json"), Some("gzip"), vec![])),
        Reply::NotJson,
        "an empty stream inflates to nothing"
    );
}

#[test]
fn other_encodings_and_ranges_pass_through_and_a_bad_stream_is_a_zlib_failure() {
    assert_eq!(
        decoded(raw(
            200,
            Some("application/json"),
            Some("identity"),
            br#"{"a":1}"#.to_vec()
        )),
        Reply::Parsed(json!({"a": 1}))
    );
    assert_eq!(
        decoded(raw(
            200,
            Some("application/json"),
            Some("br"),
            br#"{"a":1}"#.to_vec()
        )),
        Reply::Parsed(json!({"a": 1})),
        "not ours to decode"
    );
    let mut ranged = raw(206, Some("application/json"), Some("gzip"), gzip(b"{}"));
    ranged.content_range = true;
    assert_eq!(
        decode(ranged).unwrap().content_encoding.as_deref(),
        Some("gzip"),
        "Content-Range: left encoded"
    );
    for bad in [b"not gzip at all".to_vec(), vec![0x78, 0x9c, 0xff, 0xff]] {
        let f = decode(raw(200, Some("application/json"), Some("gzip"), bad)).unwrap_err();
        assert_eq!(f.cause, Cause::Other);
        assert!(f.message.starts_with("Zlib::"), "{}", f.message);
        assert!(!f.pre_transmission(), "the gem's client_error: ambiguous");
    }
}
fn st(status: u16, message: &str) -> Reply {
    Reply::Status {
        status,
        message: message.into(),
    }
}

#[test]
fn error_statuses_carry_the_raw_body_or_faradays_message() {
    assert_eq!(
        reply(
            500,
            Some("application/json"),
            r#"{"error":["EService:Unavailable"]}"#
        ),
        st(500, r#"{"error":["EService:Unavailable"]}"#)
    );
    assert_eq!(
        reply(500, Some("text/plain"), ""),
        st(
            500,
            &format!("the server responded with status 500 for POST {URL}")
        )
    );
    assert_eq!(
        reply(404, Some("text/html"), "<h1>nf</h1> é"),
        st(404, "<h1>nf</h1> é")
    );
    assert_eq!(reply(429, None, "no"), st(429, "no"));
    assert_eq!(
        reply(400, Some("application/json; charset=utf-8"), r#"{"e":1}"#),
        st(400, r#"{"e":1}"#)
    );
}

#[test]
fn json_is_parsed_only_under_a_json_media_type() {
    assert_eq!(
        reply(200, Some("application/json"), r#"{"a":1}"#),
        Reply::Parsed(json!({"a": 1}))
    );
    assert_eq!(
        reply(200, Some("application/json; charset=utf-8"), r#"{"a":1}"#),
        Reply::Parsed(json!({"a": 1}))
    );
    assert_eq!(
        reply(200, Some("application/vnd.api+json"), "[1]"),
        Reply::Parsed(json!([1]))
    );
    assert_eq!(
        reply(200, Some("Application/JSON"), r#"{"a":1}"#),
        Reply::NotJson,
        "Faraday's match is case-sensitive"
    );
    assert_eq!(reply(200, Some("text/jsonx"), r#"{"a":1}"#), Reply::NotJson);
    assert_eq!(reply(200, Some("text/html"), "<p>hi</p>"), Reply::NotJson);
    assert_eq!(reply(200, None, r#"{"a":1}"#), Reply::NotJson);
}

#[test]
fn blank_bodies_are_not_json_and_bad_ones_fail_with_the_body() {
    assert_eq!(reply(200, Some("application/json"), ""), Reply::NotJson);
    assert_eq!(
        reply(200, Some("application/json"), "  \n "),
        Reply::NotJson
    );
    assert_eq!(
        reply(200, Some("application/json"), "{not json"),
        st(200, "{not json")
    );
    assert_eq!(
        reply(200, Some("application/json"), r#"{"a""#),
        st(200, r#"{"a""#)
    );
    let dup = r#"{"dup":1,"dup":2}"#;
    assert_eq!(
        reply(200, Some("application/json"), dup),
        st(200, dup),
        "json 3.0.2 rejects duplicate keys"
    );
    let nested_dup = r#"{"result":{"x":{"k":1,"k":1}}}"#;
    assert_eq!(
        reply(200, Some("application/json"), nested_dup),
        st(200, nested_dup)
    );
}

#[test]
fn numbers_keep_their_text_and_other_statuses_parse_like_success() {
    let Reply::Parsed(v) = reply(
        200,
        Some("application/json"),
        r#"{"i":12345678901234567890123,"f":1688888888.1234,"z":-0.0}"#,
    ) else {
        panic!()
    };
    assert_eq!(v["i"].to_string(), "12345678901234567890123");
    assert_eq!(v["f"].to_string(), "1688888888.1234");
    assert_eq!(
        reply(302, Some("application/json"), r#"{"a":1}"#),
        Reply::Parsed(json!({"a": 1}))
    );
    assert_eq!(reply(302, Some("application/json"), "{"), st(302, "{"));
}

fn truncated(framing: BodyFraming) -> Raw {
    let mut r = raw(
        200,
        Some("application/json"),
        Some("gzip"),
        gzip(br#"{"a":1}"#)[..12].to_vec(),
    );
    r.framing = framing;
    r
}

#[test]
fn truncated_gzip_with_content_length_yields_an_empty_body() {
    let r = decode(truncated(BodyFraming::ContentLength)).unwrap();
    assert!(r.body.is_empty());
    assert_eq!(r.content_encoding, None);
    assert_eq!(shape("POST", URL, r), Reply::NotJson);
}

#[test]
fn truncated_gzip_with_chunked_framing_yields_an_empty_body() {
    let r = decode(truncated(BodyFraming::Chunked)).unwrap();
    assert!(r.body.is_empty());
    assert_eq!(r.content_encoding, None);
    assert_eq!(shape("POST", URL, r), Reply::NotJson);
}

#[test]
fn truncated_gzip_with_close_delimited_framing_is_an_ambiguous_failure() {
    use honeymaker_client::kraken::{VenueError, outcome};
    let f = decode(truncated(BodyFraming::CloseDelimited)).unwrap_err();
    assert_eq!(f.cause, Cause::Other);
    assert!(f.message.starts_with("Zlib::BufError:"), "{}", f.message);
    assert!(!f.pre_transmission());
    assert_eq!(
        outcome(Err(f.clone())),
        Err(VenueError::Ambiguous(f.message))
    );
}

#[test]
fn incomplete_streams_discard_only_the_pending_ruby_zlib_buffer() {
    for body in [b"{}".to_vec(), vec![b'x'; 16384 * 2 + 123]] {
        for mut compressed in [gzip(&body), zlib(&body)] {
            compressed.pop(); // Missing trailer: partial output is buffered until stream end.
            for framing in [
                BodyFraming::ContentLength,
                BodyFraming::Chunked,
                BodyFraming::CloseDelimited,
            ] {
                let mut r = raw(200, Some("text/plain"), Some("gzip"), compressed.clone());
                r.framing = framing;
                match framing {
                    BodyFraming::CloseDelimited => {
                        assert_eq!(decode(r).unwrap_err().cause, Cause::Other)
                    }
                    _ => assert_eq!(
                        &decode(r).unwrap().body[..],
                        &body[..body.len() / 16384 * 16384]
                    ),
                }
            }
        }
    }
}

#[test]
fn corruption_is_not_suppressed_by_body_framing() {
    let mut bad_crc = gzip(b"{}");
    let crc_index = bad_crc.len() - 8;
    bad_crc[crc_index] ^= 1;
    for bad in [
        b"not gzip at all".to_vec(),
        vec![0x78, 0x9c, 0xff, 0xff],
        bad_crc,
    ] {
        for framing in [
            BodyFraming::ContentLength,
            BodyFraming::Chunked,
            BodyFraming::CloseDelimited,
        ] {
            let mut r = raw(200, Some("application/json"), Some("gzip"), bad.clone());
            r.framing = framing;
            let f = decode(r).unwrap_err();
            assert_eq!(f.cause, Cause::Other);
            assert!(f.message.starts_with("Zlib::DataError:"), "{}", f.message);
            assert!(!f.pre_transmission());
        }
    }
}

#[test]
fn empty_407_uses_faradays_proxy_auth_message() {
    assert_eq!(
        reply(407, None, ""),
        st(407, "407 \"Proxy Authentication Required\"")
    );
    assert_eq!(reply(407, None, "refused"), st(407, "refused"));
}

#[test]
fn fallback_messages_uppercase_the_request_method() {
    assert_eq!(
        shape("post", URL, raw(500, None, None, vec![])),
        st(
            500,
            &format!("the server responded with status 500 for POST {URL}")
        )
    );
}

#[test]
fn recognized_encoding_headers_are_removed_even_on_empty_bodies() {
    for enc in [
        "gzip", "x-gzip", "GZIP", "deflate", "none", "identity", "IDENTITY",
    ] {
        for framing in [
            BodyFraming::ContentLength,
            BodyFraming::Chunked,
            BodyFraming::CloseDelimited,
        ] {
            let mut r = raw(200, None, Some(enc), vec![]);
            r.framing = framing;
            let r = decode(r).unwrap();
            assert_eq!(r.content_encoding, None, "{enc}");
            assert!(r.body.is_empty());
        }
        let r = decode(raw(
            200,
            None,
            Some(enc),
            if matches!(enc, "none" | "identity" | "IDENTITY") {
                b"{}".to_vec()
            } else {
                gzip(b"{}")
            },
        ))
        .unwrap();
        assert_eq!(r.content_encoding, None, "{enc}");
        assert_eq!(&r.body[..], b"{}");
        let mut ranged = raw(206, None, Some(enc), vec![]);
        ranged.content_range = true;
        assert_eq!(
            decode(ranged).unwrap().content_encoding.as_deref(),
            Some(enc)
        );
    }
    assert_eq!(
        decode(raw(200, None, Some("br"), vec![]))
            .unwrap()
            .content_encoding
            .as_deref(),
        Some("br")
    );
}

#[test]
fn json_limits_array_object_and_mixed_nesting_to_100_levels() {
    for (open, close) in [("[", "]"), ("{\"x\":", "}"), ("[{\"x\":", "}]")] {
        let levels = open.matches(['[', '{']).count();
        for depth in [100 / levels, 100 / levels + 1] {
            let body = format!("{}0{}", open.repeat(depth), close.repeat(depth));
            if depth * levels <= 100 {
                assert_eq!(
                    reply(200, Some("application/json"), &body),
                    Reply::Parsed(serde_json::from_str(&body).unwrap())
                );
            } else {
                assert_eq!(reply(200, Some("application/json"), &body), st(200, &body));
            }
        }
    }
    // Text inside strings is not nesting; arbitrary-precision number pseudo-maps aren't either.
    let body = format!(
        "{}{{\"[\\\"{{\":12345678901234567890123}}{}",
        "[".repeat(99),
        "]".repeat(99)
    );
    assert!(matches!(
        reply(200, Some("application/json"), &body),
        Reply::Parsed(_)
    ));
}

#[test]
fn empty_json_containers_do_not_increment_the_nesting_limit() {
    for leaf in ["[]", "{}"] {
        let body = format!("{}{}{}", "[".repeat(100), leaf, "]".repeat(100));
        assert_eq!(
            reply(200, Some("application/json"), &body),
            Reply::Parsed(serde_json::from_str(&body).unwrap())
        );
    }
}

#[test]
fn invalid_utf8_in_an_add_order_description_still_parses() {
    let body =
        b"{\"error\":[],\"result\":{\"txid\":[\"OTX-1\"],\"descr\":{\"order\":\"buy \xff\"}}}";
    assert_eq!(
        decoded(raw(200, Some("application/json"), None, body.to_vec())),
        Reply::Parsed(
            json!({"error": [], "result": {"txid": ["OTX-1"], "descr": {"order": "buy �"}}})
        )
    );
}

#[test]
fn invalid_utf8_does_not_relax_json_strictness() {
    for bad in [
        "NaN",
        "Infinity",
        "-Infinity",
        r#""\q""#,
        r#""\ud800""#,
        r#""\udc00""#,
        r#""\ud800\u0041""#,
        r#""\uZZZZ""#,
        "01",
        "\"raw\nnewline\"",
        r#"{"a":1,"a":2}"#,
        r#"{"a":1,"\u0061":2}"#,
        r#"{"nested":{"a":1,"a":2}}"#,
    ] {
        for prefix in [b"[".as_slice(), b"[\"\xff\","] {
            let body = [prefix, bad.as_bytes(), b"]"].concat();
            assert_eq!(
                decoded(raw(200, Some("application/json"), None, body.clone())),
                st(200, &String::from_utf8_lossy(&body)),
                "{bad}"
            );
        }
    }
    for body in [
        b"\xef\xbb\xbf{}".as_slice(),
        b"\xff{}",
        b"{\"a\":1} trailing",
    ] {
        assert_eq!(
            decoded(raw(200, Some("application/json"), None, body.to_vec())),
            st(200, &String::from_utf8_lossy(body))
        );
    }
    let body = b"[\"\xff\",\"\\ud83d\\ude00\"]";
    assert_eq!(
        decoded(raw(200, Some("application/json"), None, body.to_vec())),
        Reply::Parsed(json!(["�", "😀"]))
    );
    for depth in [100, 101] {
        let body = [
            "[".repeat(depth).as_bytes(),
            b"\"\xff\"",
            "]".repeat(depth).as_bytes(),
        ]
        .concat();
        let result = decoded(raw(200, Some("application/json"), None, body.clone()));
        if depth == 100 {
            assert!(matches!(result, Reply::Parsed(_)));
        } else {
            assert_eq!(result, st(200, &String::from_utf8_lossy(&body)));
        }
    }
}

#[test]
fn duplicate_keys_are_compared_before_lossy_decoding() {
    for body in [
        b"{\"\xff\":1,\"\xff\":2}".as_slice(),
        b"{\"\xffa\":1,\"\xff\\u0061\":2}",
        b"{\"\xff\":0,\"nested\":{\"a\":1,\"\\u0061\":2}}",
        b"{\"\xff\":0,\"nested\":{\"\xc3\xa9\":1,\"\\u00e9\":2}}",
    ] {
        assert_eq!(
            decoded(raw(200, Some("application/json"), None, body.to_vec())),
            st(200, &String::from_utf8_lossy(body))
        );
    }
    let body = b"{\"\xff\":1,\"\xfe\":2,\"\xef\xbf\xbd\":3}";
    assert!(
        matches!(
            decoded(raw(200, Some("application/json"), None, body.to_vec())),
            Reply::Parsed(_)
        ),
        "distinct byte keys must not become a duplicate-key parse error"
    );
    // Lossy key collisions must not hide an over-deep subtree when Value keeps the last key.
    let body = [
        b"{\"\xff\":".as_slice(),
        "[".repeat(100).as_bytes(),
        b"0",
        "]".repeat(100).as_bytes(),
        b",\"\xfe\":0}",
    ]
    .concat();
    assert_eq!(
        decoded(raw(200, Some("application/json"), None, body.clone())),
        st(200, &String::from_utf8_lossy(&body))
    );
}
