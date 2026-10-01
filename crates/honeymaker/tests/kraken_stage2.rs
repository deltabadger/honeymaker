use bigdecimal::BigDecimal;
use honeymaker::kraken::normalize::{self, Finished};
use serde_json::{Value, json};

fn venue<T>(f: Finished<T>) -> Option<Vec<Value>> {
    match f {
        Finished::Venue(e) => Some(e),
        _ => None,
    }
}

#[test]
fn a_venue_refusal_carries_krakens_error_array_verbatim_on_every_normalizer() {
    let body =
        json!({ "error": ["EOrder:Insufficient funds", "EGeneral:Invalid arguments:volume"] });
    let want = Some(vec![
        json!("EOrder:Insufficient funds"),
        json!("EGeneral:Invalid arguments:volume"),
    ]);
    assert_eq!(
        venue(normalize::add_order::<BigDecimal>(&body).unwrap()),
        want
    );
    assert_eq!(venue(normalize::orders::<BigDecimal>(&body).unwrap()), want);
    assert_eq!(
        venue(normalize::balances::<BigDecimal>(&body).unwrap()),
        want
    );
    assert_eq!(
        venue(normalize::tickers::<BigDecimal>(&body).unwrap()),
        want
    );
    assert_eq!(
        venue(normalize::bid_ask::<BigDecimal>(&body).unwrap()),
        want
    );
}

#[test]
fn only_a_truthy_element_makes_a_refusal_but_every_element_is_kept() {
    let ok = json!({ "error": [null, false], "result": { "txid": ["O1"] } });
    assert!(
        matches!(normalize::add_order::<BigDecimal>(&ok).unwrap(), Finished::Ok(v) if v == json!("O1"))
    );
    let mixed = json!({ "error": [null, "EAPI:Invalid key"] });
    assert_eq!(
        venue(normalize::add_order::<BigDecimal>(&mixed).unwrap()),
        Some(vec![json!(null), json!("EAPI:Invalid key")])
    );
}

use honeymaker::kraken::requests::{Param, build};
use honeymaker::kraken::sign::{Credentials, set_fixed_nonce};
use std::collections::BTreeMap;
use std::str::FromStr;
use std::sync::Mutex;

static NONCE: Mutex<()> = Mutex::new(()); // the fixed-nonce hook is process-global

fn dec(s: &str) -> BigDecimal {
    BigDecimal::from_str(s).unwrap()
}
fn load(name: &str) -> Value {
    serde_json::from_str(
        &std::fs::read_to_string(format!(
            "{}/tests/vectors/{name}",
            env!("CARGO_MANIFEST_DIR")
        ))
        .unwrap(),
    )
    .unwrap()
}
fn ok<T>(f: Finished<T>) -> T {
    match f {
        Finished::Ok(v) => v,
        _ => panic!("not Ok"),
    }
}
fn one(s: &str) -> Param {
    Param::One(s.into())
}

#[test]
fn add_order_signs_and_sends_cl_ord_id_and_deadline_exactly_as_legacy() {
    let _g = NONCE.lock().unwrap_or_else(|p| p.into_inner());
    for v in load("kraken_add_order_wire.json").as_array().unwrap() {
        let mut params = BTreeMap::new();
        for (k, x) in v["args"].as_object().unwrap() {
            let p = match x {
                Value::Array(a) => {
                    Param::Many(a.iter().map(|s| s.as_str().unwrap().to_string()).collect())
                }
                Value::Bool(b) => one(&b.to_string()),
                other => one(other.as_str().unwrap()),
            };
            params.insert(k.clone(), p);
        }
        set_fixed_nonce(v["nonce"].as_u64());
        let creds = Credentials {
            api_key: v["api_key"].as_str().unwrap().into(),
            api_secret: v["api_secret"].as_str().unwrap().into(),
        };
        let built = build("add_order", &params, Some(&creds)).unwrap();
        set_fixed_nonce(None);
        assert_eq!(built.body.as_deref(), v["body"].as_str());
        for (name, value) in v["headers"].as_object().unwrap() {
            assert!(
                built
                    .headers
                    .iter()
                    .any(|(k, x)| k == name && Some(x.as_str()) == value.as_str()),
                "{name}"
            );
        }
    }
}

#[test]
fn open_and_closed_orders_lay_out_their_filters_after_the_nonce() {
    let b = build(
        "open_orders",
        &BTreeMap::from([("cl_ord_id".to_string(), one("c-1"))]),
        None,
    )
    .unwrap();
    assert_eq!(
        (b.path, b.pairs[0].0.as_str(), &b.pairs[1..]),
        (
            "/0/private/OpenOrders",
            "nonce",
            &[("cl_ord_id".to_string(), "c-1".to_string())][..]
        )
    );
    let b = build(
        "closed_orders",
        &BTreeMap::from([
            ("ofs".to_string(), one("50")),
            ("start".to_string(), one("1727690400")),
            ("cl_ord_id".to_string(), one("c-1")),
        ]),
        None,
    )
    .unwrap();
    assert_eq!(b.path, "/0/private/ClosedOrders");
    assert_eq!(
        b.pairs[1..],
        [("cl_ord_id", "c-1"), ("start", "1727690400"), ("ofs", "50")]
            .map(|(k, v)| (k.to_string(), v.to_string()))
    );
}

fn kraken_order(cl: Option<&str>) -> Value {
    let mut o = json!({ "refid": null, "userref": 0, "status": "closed", "opentm": 1727697600.1234, "closetm": 1727697601.5,
        "descr": { "pair": "XBTEUR", "type": "buy", "ordertype": "market", "price": "0", "order": "buy 60.00000000 XBTEUR @ market" },
        "vol": "60.00000000", "vol_exec": "0.00119975", "cost": "60.00000", "fee": "0.24000", "price": "50010.5", "misc": "", "oflags": "fciq,viqc" });
    if let Some(c) = cl {
        o["cl_ord_id"] = json!(c);
    }
    o
}

#[test]
fn orders_report_their_client_order_id_and_userref() {
    let got = ok(normalize::orders::<BigDecimal>(&json!({ "error": [], "result": { "O1": kraken_order(Some("c-1")), "O2": kraken_order(None) } })).unwrap());
    assert_eq!(
        (got[0].cl_ord_id.clone(), got[0].userref.clone()),
        (Some(json!("c-1")), Some(json!(0)))
    );
    assert_eq!(got[1].cl_ord_id, None);
    assert_eq!(
        (got[0].quote_amount.clone(), got[0].amount.clone()),
        (Some(dec("60")), None),
        "viqc: vol is quote"
    );
}

#[test]
fn listed_orders_read_open_and_closed_with_the_raw_count() {
    let (open, count) = ok(normalize::listed_orders::<BigDecimal>(
        &json!({ "error": [], "result": { "open": { "O1": kraken_order(Some("c-1")) } } }),
        "open",
    )
    .unwrap());
    assert_eq!((open.len(), count), (1, None));
    let (closed, count) = ok(normalize::listed_orders::<BigDecimal>(&json!({ "error": [], "result": { "closed": { "O1": kraken_order(None), "O2": kraken_order(None) }, "count": 7 } }), "closed").unwrap());
    assert_eq!((closed.len(), count), (2, Some(json!(7))));
    let (none, count) = ok(normalize::listed_orders::<BigDecimal>(
        &json!({ "error": [], "result": { "closed": {}, "count": 0 } }),
        "closed",
    )
    .unwrap());
    assert_eq!((none.len(), count), (0, Some(json!(0))));
    // Ruling 1 (review round 1): a missing or null container is an error, never "no orders".
    for (body, key) in [
        (json!({}), "open"),
        (json!({ "error": [] }), "open"),
        (json!({ "error": [], "result": null }), "open"),
        (json!({ "error": [], "result": { "open": null } }), "open"),
        (json!({ "error": [], "result": { "count": 0 } }), "closed"),
        (
            json!({ "error": [], "result": { "closed": [1] } }),
            "closed",
        ),
        (json!({ "error": [], "result": "x" }), "closed"),
    ] {
        assert!(
            normalize::listed_orders::<BigDecimal>(&body, key).is_err(),
            "{body} {key}"
        );
    }
    assert!(matches!(
        normalize::listed_orders::<BigDecimal>(&json!("oops"), "open").unwrap(),
        Finished::Unreadable
    ));
}

#[test]
fn ticker_prices_are_the_first_pairs_bid_ask_and_last_trade() {
    let body = json!({ "error": [], "result": { "XXBTZEUR": { "a": ["50000.2", "1", "1.000"], "b": ["49990.1", "1", "1.000"], "c": ["49995.3", "0.001"] } } });
    let p = ok(normalize::ticker_prices::<BigDecimal>(&body).unwrap()).unwrap();
    assert_eq!(
        (p.bid, p.ask, p.last),
        (dec("49990.1"), dec("50000.2"), dec("49995.3"))
    );
    assert!(
        ok(normalize::ticker_prices::<BigDecimal>(&json!({ "error": [], "result": {} })).unwrap())
            .is_none()
    );
    assert!(
        normalize::ticker_prices::<BigDecimal>(
            &json!({ "error": [], "result": { "X": { "a": ["1"], "b": ["1"] } } })
        )
        .is_err(),
        "no c"
    );
    assert!(matches!(
        normalize::ticker_prices::<BigDecimal>(&json!([1])).unwrap(),
        Finished::Unreadable
    ));
}
