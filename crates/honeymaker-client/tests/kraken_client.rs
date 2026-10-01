mod support;
use bigdecimal::BigDecimal;
use chrono::{DateTime, Utc};
use honeymaker::kraken::sign::set_fixed_nonce;
use honeymaker_client::kraken::*;
use honeymaker_client::transport::Timeouts;
use serde_json::{Value, json};
use std::str::FromStr;
use std::time::Duration;
use support::*;

/// The fixed-nonce hook is process-global, so tests that fix it or read the live sequence hold this
/// across their awaits. An async mutex: a std guard held across `.await` fails clippy's
/// `await_holding_lock` under `-D warnings`.
static NONCE: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

fn dec(s: &str) -> BigDecimal {
    BigDecimal::from_str(s).unwrap()
}
fn at(s: &str) -> DateTime<Utc> {
    s.parse().unwrap()
}
/// Distinct limits, so no test can race two of them.
fn quick() -> Timeouts {
    Timeouts {
        open: Duration::from_millis(300),
        read: Duration::from_millis(400),
        write: Duration::from_millis(500),
    }
}
fn creds() -> Credentials {
    Credentials {
        api_key: "key".into(),
        api_secret: "c2VjcmV0".into(),
    }
}
fn client(k: &Kraken, credentials: Option<Credentials>) -> Client {
    Client::new(Config {
        base_url: k.url(),
        credentials,
        timeouts: quick(),
        ..Config::default()
    })
    .unwrap()
}
fn market(cl: &str) -> NewOrder {
    NewOrder {
        pair: "XBTEUR".into(),
        kind: OrderKind::Market,
        volume: "0.0012".into(),
        quote_volume: true,
        cl_ord_id: cl.into(),
        deadline: at("2026-09-30T12:00:10Z"),
    }
}
const TICKER: &str = r#"{"error":[],"result":{"XXBTZEUR":{"a":["50000.2","1","1.000"],"b":["49990.1","1","1.000"],"c":["49995.3","0.001"]}}}"#;
fn ticker() -> KReply {
    KReply::Http(200, "application/json", TICKER.into())
}
fn raw_order(
    cl: Option<&str>,
    status: &str,
    oflags: &str,
    ordertype: &str,
    price: &str,
    descr_price: &str,
) -> Value {
    let mut o = json!({ "userref": 0, "status": status, "opentm": 1727697600.1234, "vol": if oflags.contains("viqc") { "60.00000000" } else { "0.00100000" },
        "vol_exec": if status == "closed" { "0.00119975" } else { "0" }, "cost": if status == "closed" { "60.0" } else { "0" },
        "price": price, "oflags": oflags, "misc": "", "descr": { "pair": "XBTEUR", "type": "buy", "ordertype": ordertype, "price": descr_price } });
    if let Some(c) = cl {
        o["cl_ord_id"] = json!(c);
    }
    o
}

#[tokio::test(flavor = "current_thread")]
async fn prices_are_bid_ask_and_last_from_a_get_with_the_gems_headers() {
    let k = kraken(vec![("/0/public/Ticker", vec![ticker()])]).await;
    let p = client(&k, None).prices("XBTEUR").await.unwrap();
    assert_eq!(
        p,
        Prices {
            bid: dec("49990.1"),
            ask: dec("50000.2"),
            last: dec("49995.3")
        }
    );
    let r = &k.requests()[0];
    assert_eq!(
        (r.method.as_str(), r.target.as_str()),
        ("GET", "/0/public/Ticker?pair=XBTEUR")
    );
    assert_eq!(
        (r.header("user-agent"), r.header("accept")),
        (Some("Honeymaker Ruby"), Some("application/json"))
    );
}

#[tokio::test(flavor = "current_thread")]
async fn the_user_agent_is_the_callers_to_set() {
    let k = kraken(vec![("/0/public/Ticker", vec![ticker()])]).await;
    let c = Client::new(Config {
        base_url: k.url(),
        user_agent: "deltabadger-engine".into(),
        ..Config::default()
    })
    .unwrap();
    c.prices("XBTEUR").await.unwrap();
    assert_eq!(
        k.requests()[0].header("user-agent"),
        Some("deltabadger-engine")
    );
}

#[tokio::test(flavor = "current_thread")]
async fn a_ticker_refusal_or_an_empty_result_is_rejected_like_rails() {
    let k = kraken(vec![(
        "/0/public/Ticker",
        vec![
            kok(json!({ "error": ["EQuery:Unknown asset pair"] })),
            kok(json!({ "error": [], "result": {} })),
        ],
    )])
    .await;
    let c = client(&k, None);
    assert_eq!(
        c.prices("XBTEUR").await,
        Err(VenueError::Rejected(vec![
            "EQuery:Unknown asset pair".into()
        ]))
    );
    assert_eq!(
        c.prices("XBTEUR").await,
        Err(VenueError::Rejected(vec![
            "Failed to get Kraken XBTEUR ticker information".into()
        ]))
    );
}

fn wire_vectors() -> Value {
    serde_json::from_str(
        &std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../honeymaker/tests/vectors/kraken_add_order_wire.json"
        ))
        .unwrap(),
    )
    .unwrap()
}
fn vector_client(k: &Kraken, v: &Value) -> Client {
    Client::new(Config {
        base_url: k.url(),
        timeouts: quick(),
        credentials: Some(Credentials {
            api_key: v["api_key"].as_str().unwrap().into(),
            api_secret: v["api_secret"].as_str().unwrap().into(),
        }),
        ..Config::default()
    })
    .unwrap()
}

#[tokio::test(flavor = "current_thread")]
async fn add_order_sends_the_signed_request_legacy_sends() {
    let _g = NONCE.lock().await;
    let vectors = wire_vectors();
    let orders = [
        NewOrder {
            deadline: at("2026-09-30T12:00:10.000Z"),
            ..market("6f1c1a52-7c8e-4d0e-9a57-0b6f0f1d2e3a")
        },
        NewOrder {
            pair: "XBTEUR".into(),
            kind: OrderKind::Limit {
                price: "49870.1".into(),
            },
            volume: "0.00119".into(),
            quote_volume: false,
            cl_ord_id: "0d9e2c1b-2f4a-4b8c-8d1e-5a6b7c8d9e0f".into(),
            deadline: at("2026-09-30T12:00:10.123Z"),
        },
    ];
    for (v, order) in vectors.as_array().unwrap().iter().zip(orders) {
        let k = kraken(vec![("/0/private/AddOrder", vec![kok(json!({ "error": [], "result": { "descr": { "order": "buy" }, "txid": ["OTX-1"] } }))])]).await;
        set_fixed_nonce(v["nonce"].as_u64());
        let r = vector_client(&k, v).add_order(&order).await;
        set_fixed_nonce(None);
        assert_eq!(r, Ok("OTX-1".to_string()));
        let req = &k.requests()[0];
        assert_eq!(
            (req.method.as_str(), req.target.as_str()),
            ("POST", "/0/private/AddOrder")
        );
        assert_eq!(Some(req.body.as_str()), v["body"].as_str());
        assert_eq!(req.header("api-sign"), v["headers"]["API-Sign"].as_str());
        assert_eq!(
            req.header("content-type"),
            Some("application/x-www-form-urlencoded")
        );
    }
}

#[tokio::test(flavor = "current_thread")]
async fn add_order_validate_sends_validate_true_as_legacy_does() {
    let _g = NONCE.lock().await;
    let v = &wire_vectors()[2];
    let k = kraken(vec![(
        "/0/private/AddOrder",
        vec![kok(
            json!({ "error": [], "result": { "descr": { "order": "buy 60 XBTEUR @ market" } } }),
        )],
    )])
    .await;
    let order = NewOrder {
        volume: "60".into(),
        ..market("6f1c1a52-7c8e-4d0e-9a57-0b6f0f1d2e3a")
    };
    set_fixed_nonce(v["nonce"].as_u64());
    let r = vector_client(&k, v)
        .add_order_validate(&NewOrder {
            deadline: at("2026-09-30T12:00:10.000Z"),
            ..order
        })
        .await;
    set_fixed_nonce(None);
    assert_eq!(r, Ok(()));
    assert_eq!(Some(k.requests()[0].body.as_str()), v["body"].as_str());
}

#[tokio::test(flavor = "current_thread")]
async fn add_order_is_sent_exactly_once_whatever_happens() {
    let nil = "Failed to set Kraken market order (order_id is nil)";
    let cases: Vec<(KReply, Result<String, VenueError>)> = vec![
        (
            kok(json!({ "error": [], "result": { "txid": ["OTX-1"] } })),
            Ok("OTX-1".into()),
        ),
        (
            kok(json!({ "error": ["EOrder:Insufficient funds"] })),
            Err(VenueError::Rejected(vec![
                "EOrder:Insufficient funds".into(),
            ])),
        ),
        (
            kok(json!({ "error": [], "result": { "descr": { "order": "buy" } } })),
            Err(VenueError::Ambiguous(nil.into())),
        ),
        (
            kok(json!({ "error": [], "result": { "txid": [""] } })),
            Err(VenueError::Ambiguous(nil.into())),
        ),
        (
            KReply::Http(
                500,
                "application/json",
                r#"{"error":["EService:Unavailable"]}"#.into(),
            ),
            Err(VenueError::Ambiguous(
                r#"{"error":["EService:Unavailable"]}"#.into(),
            )),
        ),
        (
            KReply::Http(403, "text/html", "<html>blocked</html>".into()),
            Err(VenueError::Rejected(vec!["<html>blocked</html>".into()])),
        ),
        (
            KReply::Http(200, "text/html", "<html>maintenance</html>".into()),
            Err(VenueError::Ambiguous(UNREADABLE.into())),
        ),
        (
            KReply::Http(200, "application/json", "{".into()),
            Err(VenueError::Ambiguous("{".into())),
        ),
        (
            KReply::Close,
            Err(VenueError::Ambiguous("end of file reached".into())),
        ),
        (
            KReply::Hang,
            Err(VenueError::Ambiguous("Net::ReadTimeout".into())),
        ),
    ];
    for (reply, want) in cases {
        let k = kraken(vec![("/0/private/AddOrder", vec![reply])]).await;
        assert_eq!(
            client(&k, Some(creds())).add_order(&market("c-1")).await,
            want
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(
            (k.conns(), k.requests().len()),
            (1, 1),
            "exactly one POST for {want:?}"
        );
    }
}

#[tokio::test(flavor = "current_thread")]
async fn an_unacknowledged_limit_order_says_limit() {
    let k = kraken(vec![(
        "/0/private/AddOrder",
        vec![kok(json!({ "error": [], "result": {} }))],
    )])
    .await;
    let order = NewOrder {
        kind: OrderKind::Limit {
            price: "49870.1".into(),
        },
        ..market("c-1")
    };
    assert_eq!(
        client(&k, Some(creds())).add_order(&order).await,
        Err(VenueError::Ambiguous(
            "Failed to set Kraken limit order (order_id is nil)".into()
        ))
    );
}

#[tokio::test(flavor = "current_thread")]
async fn add_order_to_a_dead_port_is_transient() {
    let port = closed_port().await;
    let c = Client::new(Config {
        base_url: format!("http://127.0.0.1:{port}"),
        credentials: Some(creds()),
        timeouts: quick(),
        ..Config::default()
    })
    .unwrap();
    assert_eq!(
        c.add_order(&market("c-1")).await,
        Err(VenueError::Transient(format!(
            "connection refused: 127.0.0.1:{port}"
        )))
    );
}

#[tokio::test(flavor = "current_thread")]
async fn orders_are_query_orders_parsed_as_rails_parses_them() {
    let mut sell_order = raw_order(None, "closed", "", "market", "50000", "0");
    sell_order["descr"]["type"] = json!("SELL");
    let k = kraken(vec![(
        "/0/private/QueryOrders",
        vec![kok(json!({ "error": [], "result": {
        "OTX-1": raw_order(None, "closed", "fciq,viqc", "market", "50010.5", "0"),
        "OTX-2": raw_order(None, "open", "", "limit", "0", "49870.0"),
        "OTX-3": sell_order } }))],
    )])
    .await;
    let got = client(&k, Some(creds()))
        .orders(&[
            "OTX-1".into(),
            "OTX-2".into(),
            "OTX-3".into(),
            "OTX-9".into(),
        ])
        .await
        .unwrap();
    assert_eq!(got.len(), 3, "ids Kraken does not report are absent");
    assert_eq!(
        got[0],
        OrderState {
            txid: "OTX-1".into(),
            status: OrderStatus::Closed,
            price: Some(dec("50010.5")),
            amount: None,
            quote_amount: Some(dec("60")),
            amount_exec: dec("0.00119975"),
            quote_amount_exec: dec("60"),
            limit: false,
            sell: false
        }
    );
    assert!(
        got[2].sell,
        "an existing sell stays a sell (descr.type, downcased as parse_order_data does)"
    );
    assert_eq!(
        (
            got[1].status,
            got[1].price.clone(),
            got[1].amount.clone(),
            got[1].limit
        ),
        (
            OrderStatus::Open,
            Some(dec("49870")),
            Some(dec("0.001")),
            true
        )
    );
    assert!(
        k.requests()[0]
            .body
            .ends_with("&txid=OTX-1%2COTX-2%2COTX-3%2COTX-9&consolidate_taker=true"),
        "{}",
        k.requests()[0].body
    );
}

#[tokio::test(flavor = "current_thread")]
async fn a_client_order_id_is_looked_up_open_then_closed_since_the_given_time() {
    let k = kraken(vec![
        ("/0/private/OpenOrders", vec![kok(json!({ "error": [], "result": { "open": {} } }))]),
        ("/0/private/ClosedOrders", vec![kok(json!({ "error": [], "result": { "closed": { "OTX-7": raw_order(Some("c-1"), "closed", "viqc", "market", "50000", "0") }, "count": 1 } }))]),
    ]).await;
    let found = client(&k, Some(creds()))
        .order_by_client_id("c-1", at("2026-09-30T11:00:00Z"))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        (found.txid.as_str(), found.status, found.sell),
        ("OTX-7", OrderStatus::Closed, false)
    );
    let reqs = k.requests();
    assert_eq!(
        reqs.iter().map(|r| r.target.as_str()).collect::<Vec<_>>(),
        ["/0/private/OpenOrders", "/0/private/ClosedOrders"]
    );
    assert!(reqs[0].body.ends_with("&cl_ord_id=c-1"));
    assert!(
        reqs[1]
            .body
            .ends_with("&cl_ord_id=c-1&start=1790766000&ofs=0"),
        "{}",
        reqs[1].body
    );
}

#[tokio::test(flavor = "current_thread")]
async fn absence_is_reported_only_after_every_closed_page() {
    let other = |i: usize| {
        raw_order(
            Some(&format!("other-{i}")),
            "closed",
            "viqc",
            "market",
            "50000",
            "0",
        )
    };
    let k = kraken(vec![
        (
            "/0/private/OpenOrders",
            vec![kok(json!({ "error": [], "result": { "open": {} } }))],
        ),
        (
            "/0/private/ClosedOrders",
            vec![
                kok(json!({ "error": [], "result": { "closed": { "O1": other(1) }, "count": 2 } })),
                kok(json!({ "error": [], "result": { "closed": { "O2": other(2) }, "count": 2 } })),
            ],
        ),
    ])
    .await;
    assert_eq!(
        client(&k, Some(creds()))
            .order_by_client_id("c-1", at("2026-09-30T11:00:00Z"))
            .await,
        Ok(None)
    );
    assert!(k.requests()[2].body.ends_with("&ofs=1"));
}

#[tokio::test(flavor = "current_thread")]
async fn a_failed_closed_page_is_an_error_not_absence() {
    let other = raw_order(Some("other"), "closed", "viqc", "market", "50000", "0");
    for page2 in [
        KReply::Http(502, "text/html", "bad gateway".into()),
        kok(json!({ "error": ["EAPI:Rate limit exceeded"] })),
        KReply::Close,
    ] {
        let k = kraken(vec![
            ("/0/private/OpenOrders", vec![kok(json!({ "error": [], "result": { "open": {} } }))]),
            ("/0/private/ClosedOrders", vec![kok(json!({ "error": [], "result": { "closed": { "O1": other.clone() }, "count": 3 } })), page2]),
        ]).await;
        assert!(
            client(&k, Some(creds()))
                .order_by_client_id("c-1", at("2026-09-30T11:00:00Z"))
                .await
                .is_err()
        );
    }
}

#[tokio::test(flavor = "current_thread")]
async fn placement_refusals_rails_treats_as_ambiguous_keep_the_intent() {
    let ambiguous = [
        "EGeneral:Internal error",
        "EAPI:Invalid nonce",
        "EService:Unavailable",
        "EService:Busy",
        "EService:Deadline elapsed",
        "Net::ReadTimeout",
        "Net::OpenTimeout",
        "Faraday::TimeoutError",
        "Faraday::ConnectionFailed",
        "execution expired",
        "Connection reset",
        "Errno::ECONNRESET",
        "connection refused",
        "Connection refused",
        "Errno::ECONNREFUSED",
        "end of file reached",
        "unexpected eof while reading",
    ];
    for s in ambiguous {
        for reply in [
            kok(json!({ "error": [s] })),
            KReply::Http(400, "application/json", json!({ "error": [s] }).to_string()),
        ] {
            let k = kraken(vec![("/0/private/AddOrder", vec![reply])]).await;
            let r = client(&k, Some(creds())).add_order(&market("c-1")).await;
            assert!(
                matches!(r, Err(VenueError::Ambiguous(ref m)) if m.contains(s)),
                "{s}: {r:?}"
            );
        }
    }
    let k = kraken(vec![(
        "/0/private/AddOrder",
        vec![KReply::Http(
            403,
            "text/plain",
            "upstream answered HTTP 503".into(),
        )],
    )])
    .await;
    assert!(
        matches!(
            client(&k, Some(creds())).add_order(&market("c-1")).await,
            Err(VenueError::Ambiguous(_))
        ),
        "/\\bHTTP 5\\d\\d\\b/"
    );
    for definitive in [
        "EOrder:Insufficient funds",
        "EService:Market in cancel_only mode",
        "EAPI:Rate limit exceeded",
        "EGeneral:Timestamp for this request was 1200ms ahead; EService:Busy",
    ] {
        let k = kraken(vec![(
            "/0/private/AddOrder",
            vec![kok(json!({ "error": [definitive] }))],
        )])
        .await;
        assert_eq!(
            client(&k, Some(creds())).add_order(&market("c-1")).await,
            Err(VenueError::Rejected(vec![definitive.into()])),
            "{definitive}"
        );
    }
    let k = kraken(vec![(
        "/0/private/AddOrder",
        vec![kok(
            json!({ "error": ["EGeneral:Invalid arguments", "EService:Busy"] }),
        )],
    )])
    .await;
    assert_eq!(
        client(&k, Some(creds())).add_order(&market("c-1")).await,
        Err(VenueError::Ambiguous(
            "EGeneral:Invalid arguments and EService:Busy".into()
        )),
        "to_sentence of all the strings"
    );
}

#[tokio::test(flavor = "current_thread")]
async fn a_proxied_client_reaches_kraken_through_connect() {
    let pki = pki();
    let t = target(
        Tls::Trusted,
        Act::Reply(http("200 OK", "application/json", TICKER)),
        &pki,
    )
    .await;
    let p = proxy(ProxyAct::Tunnel(t.addr)).await;
    let c = Client::new(Config {
        base_url: t.https_localhost(),
        proxy: Some(format!("http://127.0.0.1:{}", p.addr.port())),
        tls_roots: Some(pki.roots.clone()),
        timeouts: quick(),
        ..Config::default()
    })
    .unwrap();
    assert_eq!(c.prices("XBTEUR").await.unwrap().last, dec("49995.3"));
    assert!(p.seen.heads()[0].starts_with("connect localhost:"));
}

#[test]
fn a_bad_proxy_fails_construction_not_the_first_call() {
    assert!(
        Client::new(Config {
            proxy: Some("socks5://h:1".into()),
            ..Config::default()
        })
        .is_err()
    );
    let d = Config::default();
    assert_eq!(
        (d.base_url.as_str(), d.user_agent.as_str()),
        ("https://api.kraken.com", "Honeymaker Ruby")
    );
}

#[tokio::test(flavor = "current_thread")]
async fn every_placement_text_outcome_sends_once_on_success_and_http_error_paths() {
    let ambiguous = [
        "EGeneral:Internal error",
        "EAPI:Invalid nonce",
        "EService:Unavailable",
        "EService:Busy",
        "EService:Deadline elapsed",
        "Net::ReadTimeout",
        "Net::OpenTimeout",
        "Faraday::TimeoutError",
        "Faraday::ConnectionFailed",
        "execution expired",
        "Connection reset",
        "Errno::ECONNRESET",
        "connection refused",
        "Connection refused",
        "Errno::ECONNREFUSED",
        "end of file reached",
        "unexpected eof while reading",
        "upstream HTTP 503 failed",
    ];
    let definitive = [
        "EOrder:Insufficient funds",
        "EAPI:Rate limit exceeded",
        "EService:Market in cancel_only mode",
        "Timestamp for this request is outside of the recvWindow; EService:Busy",
        "Timestamp for this request was 1200ms ahead; EService:Busy",
        "XHTTP 503",
        "HTTP 5030",
        "HTTP 503_suffix",
    ];
    for (messages, is_ambiguous) in [(&ambiguous[..], true), (&definitive[..], false)] {
        for message in messages {
            for status in [200, 400, 503] {
                let body = json!({"error": [message]}).to_string();
                let k = kraken(vec![(
                    "/0/private/AddOrder",
                    vec![KReply::Http(status, "application/json", body.clone())],
                )])
                .await;
                let got = client(&k, Some(creds())).add_order(&market("once")).await;
                let text = if status == 200 {
                    message.to_string()
                } else {
                    body
                };
                let want = if is_ambiguous || status >= 500 {
                    Err(VenueError::Ambiguous(text))
                } else {
                    Err(VenueError::Rejected(vec![text]))
                };
                assert_eq!(got, want, "{status}: {message}");
                assert_eq!(
                    (k.conns(), k.requests().len()),
                    (1, 1),
                    "{status}: {message}"
                );
            }
        }
    }
}

#[tokio::test(flavor = "current_thread")]
async fn malformed_add_order_results_are_ambiguous_and_sent_once() {
    for body in [
        json!(null),
        json!([]),
        json!({}),
        json!({"error": [], "result": null}),
        json!({"error": [], "result": {"txid": 42}}),
        json!({"error": [], "result": {"txid": [null]}}),
    ] {
        let k = kraken(vec![("/0/private/AddOrder", vec![kok(body)])]).await;
        assert!(matches!(
            client(&k, Some(creds())).add_order(&market("once")).await,
            Err(VenueError::Ambiguous(_))
        ));
        assert_eq!((k.conns(), k.requests().len()), (1, 1));
    }
}

#[tokio::test(flavor = "current_thread")]
async fn validate_outcomes_are_sent_once_and_need_no_txid() {
    for (reply, want) in [
        (kok(json!({"error": [], "result": {}})), Ok(())),
        (
            kok(json!({"error": ["EOrder:Insufficient funds"]})),
            Err(VenueError::Rejected(vec![
                "EOrder:Insufficient funds".into(),
            ])),
        ),
        (
            KReply::Close,
            Err(VenueError::Ambiguous("end of file reached".into())),
        ),
        (
            KReply::Hang,
            Err(VenueError::Ambiguous("Net::ReadTimeout".into())),
        ),
    ] {
        let k = kraken(vec![("/0/private/AddOrder", vec![reply])]).await;
        assert_eq!(
            client(&k, Some(creds()))
                .add_order_validate(&market("once"))
                .await,
            want
        );
        assert_eq!((k.conns(), k.requests().len()), (1, 1));
        assert!(k.requests()[0].body.contains("&validate=true"));
    }
}

#[tokio::test(flavor = "current_thread")]
async fn a_refused_proxy_sends_no_add_order_and_is_transient() {
    let p = proxy(ProxyAct::Answer(http(
        "407 Proxy Authentication Required",
        "text/plain",
        "proxy refused",
    )))
    .await;
    let c = Client::new(Config {
        base_url: "https://127.0.0.1:1".into(),
        proxy: Some(format!("http://127.0.0.1:{}", p.addr.port())),
        credentials: Some(creds()),
        timeouts: quick(),
        ..Config::default()
    })
    .unwrap();
    assert!(matches!(
        c.add_order(&market("once")).await,
        Err(VenueError::Transient(_))
    ));
    assert_eq!(p.seen.conns(), 1);
    assert_eq!(p.seen.heads().len(), 1);
    assert!(p.seen.heads()[0].starts_with("connect "));
    assert!(!p.seen.heads()[0].contains("AddOrder"));
}

#[tokio::test(flavor = "current_thread")]
async fn an_open_match_finishes_without_reading_closed_orders() {
    let k = kraken(vec![(
        "/0/private/OpenOrders",
        vec![kok(json!({"error": [], "result": {"open": {
            "OTX-OPEN": raw_order(Some("c-1"), "open", "", "limit", "0", "49870")
        }}}))],
    )])
    .await;
    let found = client(&k, Some(creds()))
        .order_by_client_id("c-1", at("2026-09-30T11:00:00Z"))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        (found.txid.as_str(), found.status),
        ("OTX-OPEN", OrderStatus::Open)
    );
    assert_eq!(k.requests().len(), 1);
}

#[tokio::test(flavor = "current_thread")]
async fn incomplete_or_unreadable_lookups_never_report_absence() {
    let other = raw_order(Some("other"), "closed", "", "market", "50000", "0");
    for pages in [
        vec![kok(json!({"error": [], "result": {"closed": {}}}))],
        vec![kok(
            json!({"error": [], "result": {"closed": {}, "count": 1}}),
        )],
        vec![kok(
            json!({"error": [], "result": {"closed": {"O1": other.clone()}, "count": 2}}),
        )],
        vec![
            kok(json!({"error": [], "result": {"closed": {"O1": other.clone()}, "count": 3}})),
            kok(json!({"error": [], "result": {"closed": {"O2": other.clone()}, "count": 1}})),
            kok(json!({"error": [], "result": {"closed": {}, "count": 1}})),
        ],
        vec![kok(json!({"error": [], "result": {"closed": []}}))],
        vec![kok(
            json!({"error": [], "result": {"closed": {"O1": {"status": "closed", "vol": "bad"}}, "count": 1}}),
        )],
    ] {
        let k = kraken(vec![
            (
                "/0/private/OpenOrders",
                vec![kok(json!({"error": [], "result": {"open": {}}}))],
            ),
            ("/0/private/ClosedOrders", pages),
        ])
        .await;
        assert!(matches!(
            client(&k, Some(creds()))
                .order_by_client_id("c-1", at("2026-09-30T11:00:00Z"))
                .await,
            Err(VenueError::Ambiguous(_))
        ));
    }
}

#[tokio::test(flavor = "current_thread")]
async fn fills_are_trades_history_aggregated_per_order_since_the_given_time() {
    let t = |o: &str, ty: &str, vol: &str, cost: &str| json!({ "ordertxid": o, "vol": vol, "cost": cost, "fee": "0.1", "type": ty, "ordertype": "market", "pair": "XXBTZEUR", "time": 1.5 });
    let k = kraken(vec![("/0/private/TradesHistory", vec![
        kok(json!({ "error": [], "result": { "trades": { "T1": t("OTX-5", "buy", "0.0006", "30.0"), "T2": t("OTX-8", "sell", "1", "2") }, "count": 3 } })),
        kok(json!({ "error": [], "result": { "trades": { "T3": t("OTX-5", "buy", "0.0006", "30.012") }, "count": 3 } })),
    ])]).await;
    let fills = client(&k, Some(creds()))
        .fills_from_trades(
            &["OTX-5".into(), "OTX-8".into()],
            at("2026-09-30T10:00:00Z"),
        )
        .await
        .unwrap();
    assert_eq!(
        fills[0],
        OrderState {
            txid: "OTX-5".into(),
            status: OrderStatus::Closed,
            price: Some(dec("50010")),
            amount: None,
            quote_amount: None,
            amount_exec: dec("0.0012"),
            quote_amount_exec: dec("60.012"),
            limit: false,
            sell: false
        }
    );
    assert!(
        fills[1].sell && fills[1].txid == "OTX-8",
        "a sell's trades aggregate as a sell"
    );
    let reqs = k.requests();
    assert!(
        reqs[0].body.ends_with("&start=1790762400&ofs=0")
            && reqs[1].body.ends_with("&start=1790762400&ofs=2")
    );
    assert!(
        reqs.iter().all(|r| !r.body.contains("end=")),
        "no `end`: it could filter out fills on clock skew (R22)"
    );
}

#[tokio::test(flavor = "current_thread")]
async fn fills_fail_rather_than_return_a_partial_scan() {
    let t = json!({ "ordertxid": "OTX-9", "vol": "1", "cost": "1", "fee": "0", "type": "buy", "ordertype": "market" });
    // Page cap: every page has one unrelated trade and Kraken says there are a thousand.
    let pages: Vec<KReply> = (0..TRADES_MAX_PAGES).map(|i| kok(json!({ "error": [], "result": { "trades": { format!("T{i}"): t.clone() }, "count": 1000 } }))).collect();
    let k = kraken(vec![("/0/private/TradesHistory", pages)]).await;
    assert!(matches!(
        client(&k, Some(creds()))
            .fills_from_trades(&["OTX-5".into()], at("2026-09-30T10:00:00Z"))
            .await,
        Err(VenueError::Ambiguous(_))
    ));
    assert_eq!(k.requests().len(), TRADES_MAX_PAGES as usize);
    // No count, and a premature empty page.
    for page in [
        json!({ "error": [], "result": { "trades": { "T1": t.clone() } } }),
        json!({ "error": [], "result": { "trades": {}, "count": 5 } }),
    ] {
        let k = kraken(vec![("/0/private/TradesHistory", vec![kok(page)])]).await;
        assert!(
            client(&k, Some(creds()))
                .fills_from_trades(&["OTX-5".into()], at("2026-09-30T10:00:00Z"))
                .await
                .is_err()
        );
    }
}

#[tokio::test(flavor = "current_thread")]
async fn orders_of_no_txids_is_empty_without_a_request() {
    let k = kraken(vec![]).await;
    assert_eq!(client(&k, Some(creds())).orders(&[]).await, Ok(vec![]));
    assert!(k.requests().is_empty());
}

#[tokio::test(flavor = "current_thread")]
async fn balance_is_rails_free_balance_of_the_asset() {
    let k = kraken(vec![("/0/private/BalanceEx", vec![kok(json!({ "error": [], "result": { "ZEUR": { "balance": "1000.5", "hold_trade": "0.5" } } }))])]).await;
    let c = client(&k, Some(creds()));
    assert_eq!(c.balance("EUR").await, Ok(dec("1000")));
    assert_eq!(c.balance("USD").await, Ok(dec("0")));
}

#[tokio::test(flavor = "current_thread")]
async fn balance_without_hold_trade_is_ambiguous_not_the_whole_balance() {
    let k = kraken(vec![(
        "/0/private/BalanceEx",
        vec![kok(
            json!({ "error": [], "result": { "ZEUR": { "balance": "1000.5" } } }),
        )],
    )])
    .await;
    assert!(matches!(
        client(&k, Some(creds())).balance("EUR").await,
        Err(VenueError::Ambiguous(_))
    ));
}

#[tokio::test(flavor = "current_thread")]
async fn without_credentials_a_private_call_goes_unsigned_and_kraken_refuses_it() {
    let k = kraken(vec![(
        "/0/private/BalanceEx",
        vec![kok(json!({ "error": ["EAPI:Invalid key"] }))],
    )])
    .await;
    assert_eq!(
        client(&k, None).balance("EUR").await,
        Err(VenueError::Rejected(vec!["EAPI:Invalid key".into()]))
    );
    assert_eq!(k.requests()[0].header("api-key"), None);
}

#[tokio::test(flavor = "current_thread")]
async fn clients_for_one_key_share_one_increasing_nonce_sequence() {
    let _g = NONCE.lock().await;
    let k = kraken(vec![(
        "/0/private/BalanceEx",
        vec![kok(json!({ "error": [], "result": {} }))],
    )])
    .await;
    let (a, b) = (client(&k, Some(creds())), client(&k, Some(creds())));
    for _ in 0..5 {
        a.balance("EUR").await.unwrap();
        b.balance("EUR").await.unwrap();
    }
    let nonces: Vec<u64> = k
        .requests()
        .iter()
        .map(|r| {
            r.body
                .strip_prefix("nonce=")
                .unwrap()
                .split('&')
                .next()
                .unwrap()
                .parse()
                .unwrap()
        })
        .collect();
    assert!(nonces.windows(2).all(|w| w[0] < w[1]), "{nonces:?}");
}
