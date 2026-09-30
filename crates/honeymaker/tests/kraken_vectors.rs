use bigdecimal::BigDecimal;
use honeymaker::encode::{ruby_decode64, www_form};
use honeymaker::kraken::sign::{Credentials, private_headers};
use honeymaker::num::Num;
use serde_json::Value;
use std::str::FromStr;

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

fn pairs(v: &Value) -> Vec<(String, String)> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|p| {
            (
                p[0].as_str().unwrap().to_string(),
                p[1].as_str().unwrap().to_string(),
            )
        })
        .collect()
}

#[test]
fn signing_is_byte_identical_to_legacy() {
    for case in load("kraken_signing.json").as_array().unwrap() {
        let body = www_form(&pairs(&case["pairs"]));
        assert_eq!(body, case["body"].as_str().unwrap(), "body");
        let secret = case["api_secret"].as_str().unwrap();
        let hex: String = ruby_decode64(secret.as_bytes())
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        assert_eq!(
            hex,
            case["decoded_secret_hex"].as_str().unwrap(),
            "decode64({secret:?})"
        );
        let creds = Credentials {
            api_key: case["api_key"].as_str().unwrap().into(),
            api_secret: secret.into(),
        };
        let mut got = private_headers(case["path"].as_str().unwrap(), &body, Some(&creds));
        got.sort();
        let mut want: Vec<(String, String)> = case["headers"]
            .as_object()
            .unwrap()
            .iter()
            .map(|(k, v)| (k.clone(), v.as_str().unwrap().to_string()))
            .collect();
        want.sort();
        assert_eq!(got, want, "headers for {case}");
    }
}

#[test]
fn rust_decimal_impl_agrees_with_ruby_on_finite_values() {
    for case in load("decimal.json").as_array().unwrap() {
        let got = <BigDecimal as Num>::parse(case["input"].as_str().unwrap());
        if !case["ok"].as_bool().unwrap() {
            assert!(got.is_err(), "{case} must not parse");
        } else if case["finite"].as_bool().unwrap() {
            assert_eq!(
                got.unwrap(),
                BigDecimal::from_str(case["plain"].as_str().unwrap()).unwrap(),
                "{case}"
            );
        }
    }
}
