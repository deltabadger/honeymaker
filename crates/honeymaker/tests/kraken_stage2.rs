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
