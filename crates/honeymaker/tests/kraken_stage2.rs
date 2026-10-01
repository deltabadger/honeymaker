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

use honeymaker::kraken::lookup::{ClientIdLookup, MAX_CLOSED_PAGES, Step};

fn open(orders: Value) -> Value {
    json!({ "error": [], "result": { "open": orders } })
}
fn closed(orders: Value, count: Value) -> Value {
    json!({ "error": [], "result": { "closed": orders, "count": count } })
}
fn others(from: usize, n: usize) -> Value {
    Value::Object(
        (from..from + n)
            .map(|i| (format!("OX{i}"), kraken_order(Some(&format!("other-{i}")))))
            .collect(),
    )
}
fn param(p: &BTreeMap<String, Param>, k: &str) -> Option<String> {
    p.get(k).map(|v| match v {
        Param::One(s) => s.clone(),
        Param::Many(m) => m.join(","),
    })
}

/// Drives the lookup over scripted bodies; returns the calls it made and how it ended.
#[allow(clippy::type_complexity)] // Preserve the brief's scripted-call helper signature.
fn run(
    pages: Vec<Value>,
) -> (
    Vec<(String, Option<String>, Option<String>)>,
    Step<BigDecimal>,
) {
    let mut l = ClientIdLookup::new("c-1", 1_727_690_400);
    let mut pages = pages.into_iter();
    let mut calls = vec![];
    let mut step = l.first::<BigDecimal>();
    loop {
        match step {
            Step::Call(op, p) => {
                assert_eq!(
                    param(&p, "cl_ord_id").as_deref(),
                    Some("c-1"),
                    "the filter goes to Kraken"
                );
                calls.push((op.to_string(), param(&p, "start"), param(&p, "ofs")));
                // A shape error is how the client learns of an unreadable page: it becomes Ambiguous.
                step = match l.feed::<BigDecimal>(
                    &pages
                        .next()
                        .expect("lookup asked for more pages than scripted"),
                ) {
                    Ok(next) => next,
                    Err(e) => return (calls, Step::Incomplete(format!("unreadable: {e:?}"))),
                };
            }
            other => return (calls, other),
        }
    }
}

#[test]
fn an_open_order_is_found_without_reading_closed_orders() {
    let (calls, end) = run(vec![open(json!({ "O1": kraken_order(Some("c-1")) }))]);
    assert!(matches!(end, Step::Found(o) if o.order_id == json!("O1")));
    assert_eq!(calls, vec![("open_orders".into(), None, None)]);
}

#[test]
fn a_closed_order_is_found_on_a_later_page_when_the_filter_is_ignored() {
    let mut page2 = others(50, 9);
    page2["O-MINE"] = kraken_order(Some("c-1"));
    let (calls, end) = run(vec![
        open(json!({})),
        closed(others(0, 50), json!(60)),
        closed(page2, json!(60)),
    ]);
    assert!(matches!(end, Step::Found(o) if o.order_id == json!("O-MINE")));
    assert_eq!(
        calls[1..],
        [
            (
                "closed_orders".into(),
                Some("1727690400".into()),
                Some("0".into())
            ),
            (
                "closed_orders".into(),
                Some("1727690400".into()),
                Some("50".into())
            )
        ]
    );
}

#[test]
fn absence_needs_every_closed_page() {
    let (calls, end) = run(vec![
        open(json!({})),
        closed(others(0, 2), json!(3)),
        closed(others(2, 1), json!(3)),
    ]);
    assert!(matches!(end, Step::Absent));
    assert_eq!(calls.len(), 3);
    let (_, end) = run(vec![open(json!({})), closed(json!({}), json!(0))]);
    assert!(
        matches!(end, Step::Absent),
        "no orders at all, stated explicitly, is a complete answer"
    );
}

#[test]
fn absence_needs_every_distinct_closed_order_not_just_enough_rows() {
    let order = |id: &str| (id.to_string(), kraken_order(Some(&format!("other-{id}"))));
    let page = |ids: &[&str]| Value::Object(ids.iter().map(|&i| order(i)).collect());
    // {A,B} then {B}, count 3: three rows served, two distinct orders, C never read.
    let (calls, end) = run(vec![
        open(json!({})),
        closed(page(&["A", "B"]), json!(3)),
        closed(page(&["B"]), json!(3)),
    ]);
    assert!(
        matches!(end, Step::Incomplete(_)),
        "never Absent with an order unread"
    );
    assert_eq!(calls.len(), 3);
    // {A,B} then {B,C}: an overlap that does cover every order.
    let (calls, end) = run(vec![
        open(json!({})),
        closed(page(&["A", "B"]), json!(3)),
        closed(page(&["B", "C"]), json!(3)),
    ]);
    assert!(matches!(end, Step::Absent));
    assert_eq!(
        calls[2].2.as_deref(),
        Some("2"),
        "ofs stays the raw row offset"
    );
    // A count that shrinks between pages never lowers the bar (R22).
    let (_, end) = run(vec![
        open(json!({})),
        closed(page(&["A", "B"]), json!(4)),
        closed(page(&["C"]), json!(3)),
        closed(json!({}), json!(3)),
    ]);
    assert!(
        matches!(end, Step::Incomplete(_)),
        "3 distinct orders against the 4 first reported"
    );
}

#[test]
fn a_missing_or_null_container_is_never_absence() {
    // `{}` for OpenOrders, then an empty ClosedOrders: must not conclude "not placed".
    let (calls, end) = run(vec![json!({}), closed(json!({}), json!(0))]);
    assert!(matches!(end, Step::Incomplete(_)));
    assert_eq!(calls.len(), 1, "stops at the unreadable OpenOrders answer");
    let (_, end) = run(vec![open(json!(null)), closed(json!({}), json!(0))]);
    assert!(matches!(end, Step::Incomplete(_)));
    let (_, end) = run(vec![
        open(json!({})),
        json!({ "error": [], "result": { "count": 0 } }),
    ]);
    assert!(
        matches!(end, Step::Incomplete(_)),
        "`closed` missing with count 0"
    );
}

#[test]
fn an_order_with_another_or_no_client_id_is_not_a_match() {
    let (_, end) = run(vec![
        open(json!({ "O1": kraken_order(None), "O2": kraken_order(Some("c-10")) })),
        closed(json!({}), json!(0)),
    ]);
    assert!(matches!(end, Step::Absent));
}

#[test]
fn anything_short_of_a_complete_scan_is_never_absence() {
    let (_, end) = run(vec![
        open(json!({})),
        closed(others(0, 2), json!(5)),
        json!({ "error": ["EAPI:Rate limit exceeded"] }),
    ]);
    assert!(matches!(end, Step::Venue(e) if e == vec![json!("EAPI:Rate limit exceeded")]));
    let (_, end) = run(vec![
        open(json!({})),
        closed(others(0, 2), json!(5)),
        json!("<html>"),
    ]);
    assert!(matches!(end, Step::Unreadable));
    let (_, end) = run(vec![
        open(json!({})),
        closed(others(0, 2), json!(5)),
        closed(json!({}), json!(5)),
    ]);
    assert!(
        matches!(end, Step::Incomplete(_)),
        "an empty page before count"
    );
    for bad in [json!(null), json!("3"), json!(-1), json!(2.5)] {
        let (_, end) = run(vec![open(json!({})), closed(json!({}), bad.clone())]);
        assert!(matches!(end, Step::Incomplete(_)), "count {bad}");
    }
    let mut pages = vec![open(json!({}))];
    pages.extend((0..MAX_CLOSED_PAGES as usize).map(|i| closed(others(i, 1), json!(1_000_000))));
    let (calls, end) = run(pages);
    assert!(matches!(end, Step::Incomplete(_)), "the page cap");
    assert_eq!(calls.len(), 1 + MAX_CLOSED_PAGES as usize);
}

#[test]
fn lookup_requests_never_bound_the_scan_with_end() {
    let mut lookup = ClientIdLookup::new("c-1", 1_727_690_400);
    let first = lookup.first::<BigDecimal>();
    let second = lookup.feed::<BigDecimal>(&open(json!({}))).unwrap();
    let third = lookup
        .feed::<BigDecimal>(&closed(others(0, 1), json!(2)))
        .unwrap();
    for step in [first, second, third] {
        let Step::Call(_, params) = step else {
            panic!("expected a request");
        };
        assert!(!params.contains_key("end"));
    }
}

#[test]
fn lookup_propagates_container_shape_errors_on_both_endpoints() {
    for key in ["open", "closed"] {
        let mut bodies = vec![json!({}), json!({ "error": [] })];
        for malformed in [json!(null), json!([]), json!("bad"), json!(1), json!(false)] {
            bodies.push(json!({ "error": [], "result": malformed }));
            bodies.push(json!({ "error": [], "result": { key: malformed, "count": 0 } }));
        }
        bodies.push(json!({ "error": [], "result": { "count": 0 } }));
        for body in bodies {
            let mut lookup = ClientIdLookup::new("c-1", 1_727_690_400);
            if key == "closed" {
                assert!(matches!(
                    lookup.feed::<BigDecimal>(&open(json!({}))).unwrap(),
                    Step::Call("closed_orders", _)
                ));
            }
            assert!(lookup.feed::<BigDecimal>(&body).is_err(), "{key}: {body}");
        }
    }
}

#[test]
fn a_growing_count_requires_the_additional_distinct_orders() {
    let (calls, end) = run(vec![
        open(json!({})),
        closed(others(0, 1), json!(2)),
        closed(others(1, 1), json!(3)),
        closed(others(2, 1), json!(3)),
    ]);
    assert!(matches!(end, Step::Absent));
    assert_eq!(calls.len(), 4);
    assert_eq!(calls[3].2.as_deref(), Some("2"));
}

#[test]
fn a_missing_closed_count_is_incomplete() {
    let (_, end) = run(vec![
        open(json!({})),
        json!({ "error": [], "result": { "closed": {} } }),
    ]);
    assert!(matches!(end, Step::Incomplete(_)));
}

#[test]
fn the_last_allowed_closed_page_can_complete_the_scan() {
    for found in [false, true] {
        let mut pages = vec![open(json!({}))];
        pages.extend((0..MAX_CLOSED_PAGES as usize).map(|i| {
            let orders = if found && i + 1 == MAX_CLOSED_PAGES as usize {
                json!({ "O-MINE": kraken_order(Some("c-1")) })
            } else {
                others(i, 1)
            };
            closed(orders, json!(MAX_CLOSED_PAGES))
        }));
        let (calls, end) = run(pages);
        if found {
            assert!(matches!(end, Step::Found(o) if o.order_id == json!("O-MINE")));
        } else {
            assert!(matches!(end, Step::Absent));
        }
        assert_eq!(calls.len(), 1 + MAX_CLOSED_PAGES as usize);
    }
}

#[test]
fn free_balance_follows_rails_last_entry_wins_rule() {
    let fb =
        |body: Value, sym: &str| ok(normalize::free_balance::<BigDecimal>(&body, sym).unwrap());
    let body = json!({ "error": [], "result": { "ZEUR": { "balance": "1000.5", "hold_trade": "0.5" }, "XXBT": { "balance": "0.01", "hold_trade": "0" } } });
    assert_eq!(fb(body.clone(), "EUR"), dec("1000"));
    assert_eq!(fb(body.clone(), "XBT"), dec("0.01"));
    assert_eq!(
        fb(body, "USD"),
        dec("0"),
        "absent: Rails' {{ free: 0 }} default"
    );
    // Rails assigns balances[asset.id] per entry: a later EUR.HOLD replaces ZEUR, zeros included.
    let later = json!({ "error": [], "result": { "ZEUR": { "balance": "100", "hold_trade": "0" }, "EUR.HOLD": { "balance": "0", "hold_trade": "0" } } });
    assert_eq!(fb(later, "EUR"), dec("0"));
    assert_eq!(
        fb(
            json!({ "error": [], "result": { "ZUSD": { "balance": "5" } } }),
            "USD"
        ),
        dec("5"),
        "no hold_trade"
    );
}
