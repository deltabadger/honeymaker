//! The strict Rust scan against the gem's Ruby loop (script/vectors/kraken_stage2.rb, part B).
//! "same": identical requests and the same end (aggregates, refusal, unreadable, or an exception,
//! which is a shape error here). "incomplete" / "error": Ruby returned a partial answer, or skipped a
//! malformed record; Rust must end Incomplete / with a shape error, having made no request Ruby
//! did not make.
use bigdecimal::BigDecimal;
use honeymaker::kraken::requests::Param;
use honeymaker::kraken::trades::{TradesPager, TradesStep};
use serde_json::{Value, json};
use std::collections::{BTreeMap, VecDeque};
use std::str::FromStr;

fn load() -> Value {
    serde_json::from_str(
        &std::fs::read_to_string(format!(
            "{}/tests/vectors/kraken_trades_pager.json",
            env!("CARGO_MANIFEST_DIR")
        ))
        .unwrap(),
    )
    .unwrap()
}
fn int(p: &BTreeMap<String, Param>, k: &str) -> Value {
    match p.get(k) {
        Some(Param::One(s)) => json!(s.parse::<i64>().unwrap()),
        _ => Value::Null,
    }
}
fn dec(v: &Value) -> BigDecimal {
    BigDecimal::from_str(v.as_str().unwrap()).unwrap()
}

/// Runs the pager over the pages; returns the (start, ofs) of each request and how it ended.
fn scan(
    ids: Vec<String>,
    start: Option<i64>,
    max_pages: u32,
    pages: Vec<Value>,
) -> (Vec<Value>, Value) {
    let mut pages: VecDeque<Value> = pages.into();
    let mut pager = TradesPager::new(ids, start, max_pages);
    let mut requests = vec![];
    let mut step = pager.start::<BigDecimal>();
    let end = loop {
        match step {
            Err(_) => break json!({ "raise": true }),
            Ok(TradesStep::Call(p)) => {
                assert!(
                    !p.contains_key("end_time"),
                    "no `end`: it would filter out fills on clock skew (R22)"
                );
                requests.push(json!([int(&p, "start"), int(&p, "ofs")]));
                step = pager.feed::<BigDecimal>(&pages.pop_front().unwrap_or(Value::Null)); // legacy: queue.shift || "null"
            }
            Ok(TradesStep::Done(v)) => {
                break json!({ "done": v.iter().map(|(t, a)| json!({
                "txid": t, "vol": a.vol.to_string(), "cost": a.cost.to_string(), "fee": a.fee.to_string(),
                "price": a.price.as_ref().map(|p| p.to_string()), "side": a.side, "order_type": a.order_type.as_str() })).collect::<Vec<_>>() });
            }
            Ok(TradesStep::Venue(e)) => break json!({ "venue": e }),
            Ok(TradesStep::Unreadable) => break json!({ "unreadable": true }),
            Ok(TradesStep::Incomplete(_)) => break json!({ "incomplete": true }),
        }
    };
    (requests, end)
}

#[test]
fn the_strict_scan_matches_the_ruby_loop_or_refuses_its_partial_answers() {
    for case in load().as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let ids = case["order_ids"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap().to_string())
            .collect();
        let pages = case["pages"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| serde_json::from_str(t.as_str().unwrap()).unwrap())
            .collect();
        let (requests, outcome) = scan(
            ids,
            case["start"].as_i64(),
            case["max_pages"].as_u64().unwrap() as u32,
            pages,
        );
        let ruby_requests = case["requests"].as_array().unwrap();
        let refused = match case["strict"].as_str().unwrap() {
            "incomplete" => Some(json!({ "incomplete": true })),
            "error" => Some(json!({ "raise": true })),
            _ => None,
        };
        if let Some(want) = refused {
            assert_eq!(
                outcome, want,
                "{name}: Ruby's answer is partial or skipped a malformed record; Rust must fail"
            );
            assert!(
                requests.len() <= ruby_requests.len()
                    && requests[..] == ruby_requests[..requests.len()],
                "{name}: a prefix of Ruby's requests"
            );
            continue;
        }
        assert_eq!(
            &Value::Array(requests),
            &case["requests"],
            "{name}: requests"
        );
        let want = &case["outcome"];
        if want.get("raise").is_some() {
            assert_eq!(
                outcome,
                json!({ "raise": true }),
                "{name}: Ruby raised {}",
                want["raise"]
            );
        } else if let Some(ok) = want.get("ok") {
            let got = outcome["done"]
                .as_array()
                .unwrap_or_else(|| panic!("{name}: {outcome}"));
            assert_eq!(got.len(), ok.as_array().unwrap().len(), "{name}");
            for (g, w) in got.iter().zip(ok.as_array().unwrap()) {
                let (txid, w) = (&w[0], &w[1]);
                assert_eq!(&g["txid"], txid, "{name}: order of first appearance");
                for k in ["vol", "cost", "fee"] {
                    assert_eq!(dec(&g[k]), dec(&w[k]), "{name}: {k}");
                }
                match (&w["price"], &g["price"]) {
                    (Value::Null, Value::Null) => {}
                    (r, g) if !g.is_null() => assert_eq!(dec(g), dec(r), "{name}: price"),
                    other => panic!("{name}: price {other:?}"),
                }
                assert_eq!(
                    (&g["side"], &g["order_type"]),
                    (&w["side"], &w["order_type"]),
                    "{name}"
                );
            }
        } else {
            assert_eq!(&outcome, want, "{name}");
        }
    }
}

fn page(trades: Value, count: u64) -> Value {
    json!({ "error": [], "result": { "trades": trades, "count": count } })
}
fn t(o: &str, vol: &str, cost: &str) -> Value {
    json!({ "ordertxid": o, "vol": vol, "cost": cost, "fee": "0.1", "type": "buy", "ordertype": "market" })
}

#[test]
fn a_fill_beyond_the_cap_is_an_error() {
    let (requests, end) = scan(
        vec!["O1".into()],
        Some(1),
        2,
        vec![
            page(json!({ "T1": t("O9", "1", "1") }), 3),
            page(json!({ "T2": t("O9", "1", "1") }), 3),
            page(json!({ "T3": t("O1", "1", "1") }), 3),
        ],
    );
    assert_eq!(
        (requests.len(), end),
        (2, json!({ "incomplete": true })),
        "never Ok([]) with O1's fill unread"
    );
}

#[test]
fn a_trade_on_two_pages_counts_once_and_completion_needs_every_distinct_trade() {
    let (_, end) = scan(
        vec!["O1".into()],
        Some(1),
        20,
        vec![
            page(
                json!({ "T1": t("O1", "1", "2"), "T2": t("O1", "3", "9") }),
                3,
            ),
            page(
                json!({ "T2": t("O1", "3", "9"), "T3": t("O1", "1", "1") }),
                3,
            ),
        ],
    );
    let o1 = &end["done"][0];
    assert_eq!(
        (dec(&o1["vol"]), dec(&o1["cost"]), dec(&o1["fee"])),
        (dec(&json!("5")), dec(&json!("12")), dec(&json!("0.3")))
    );
    // Rows served reach count 3, but only two distinct trades were seen: never Done.
    let (_, end) = scan(
        vec!["O1".into()],
        Some(1),
        20,
        vec![
            page(
                json!({ "T1": t("O1", "1", "2"), "T2": t("O1", "3", "9") }),
                3,
            ),
            page(json!({ "T2": t("O1", "3", "9") }), 3),
        ],
    );
    assert_eq!(end, json!({ "incomplete": true }));
}

#[test]
fn trades_arriving_mid_scan_fail_closed() {
    // A new trade lands at the top after page 1: rows shift, T2 is served again, count grows to 4,
    // and the newcomer is never read. Never Done with a fill possibly missing.
    let (requests, end) = scan(
        vec!["O1".into()],
        Some(1),
        20,
        vec![
            page(
                json!({ "T1": t("O1", "1", "2"), "T2": t("O1", "1", "2") }),
                3,
            ),
            page(
                json!({ "T2": t("O1", "1", "2"), "T3": t("O1", "1", "2") }),
                4,
            ),
        ],
    );
    assert_eq!((requests.len(), end), (2, json!({ "incomplete": true })));
    // A count that shrinks between pages never lowers the bar.
    let (_, end) = scan(
        vec!["O1".into()],
        Some(1),
        20,
        vec![
            page(
                json!({ "T1": t("O1", "1", "2"), "T2": t("O1", "1", "2") }),
                4,
            ),
            page(json!({ "T3": t("O1", "1", "2") }), 3),
            page(json!({}), 3),
        ],
    );
    assert_eq!(
        end,
        json!({ "incomplete": true }),
        "3 distinct trades against the 4 first reported"
    );
}

#[test]
fn malformed_fills_data_is_never_an_empty_answer() {
    for trades in [
        json!(null),
        json!(false),
        json!([]),
        json!(""),
        json!("x"),
        json!([1]),
    ] {
        let (_, end) = scan(
            vec!["O1".into()],
            Some(1),
            20,
            vec![page(trades.clone(), 0)],
        );
        assert_eq!(
            end,
            json!({ "incomplete": true }),
            "trades {trades} with count 0"
        );
    }
    let (_, end) = scan(
        vec!["O1".into()],
        Some(1),
        20,
        vec![json!({ "error": [], "result": { "count": 0 } })],
    );
    assert_eq!(
        end,
        json!({ "incomplete": true }),
        "trades missing with count 0"
    );
    for record in [
        json!("broken"),
        json!(5),
        json!(null),
        json!({ "vol": "1" }),
        json!({ "ordertxid": 5 }),
        json!({ "ordertxid": null }),
    ] {
        let (_, end) = scan(
            vec!["O1".into()],
            Some(1),
            20,
            vec![page(json!({ "T1": record.clone() }), 1)],
        );
        assert_eq!(
            end,
            json!({ "raise": true }),
            "record {record}: an error, never skipped"
        );
    }
}
