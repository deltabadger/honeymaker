use super::sign::{Credentials, next_nonce, private_headers, public_headers};
use crate::encode::www_form;
use std::collections::BTreeMap;

#[derive(Clone, Debug)]
pub enum Param {
    One(String),
    Many(Vec<String>),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Method {
    Get,
    Post,
}

pub struct Built {
    pub method: Method,
    pub path: &'static str,
    /// GET: query params in legacy order (Faraday encodes and sorts them). POST: the body's pairs.
    pub pairs: Vec<(String, String)>,
    /// POST only: the exact form body that is signed.
    pub body: Option<String>,
    pub headers: Vec<(String, String)>,
}

pub type Fields = &'static [(&'static str, &'static str)];

/// Wire order and names as in the legacy hash literals, `(wire name, param name)`. "nonce" goes
/// first for private calls.
pub fn layout(op: &str) -> Option<(Method, &'static str, Fields)> {
    use Method::*;
    Some(match op {
        "query_orders_info" => (
            Post,
            "/0/private/QueryOrders",
            &[
                ("trades", "trades"),
                ("userref", "userref"),
                ("txid", "txid"),
                ("consolidate_taker", "consolidate_taker"),
            ],
        ),
        "add_order" => (
            Post,
            "/0/private/AddOrder",
            &[
                ("ordertype", "ordertype"),
                ("type", "type"),
                ("volume", "volume"),
                ("pair", "pair"),
                ("userref", "userref"),
                ("cl_ord_id", "cl_ord_id"),
                ("displayvol", "displayvol"),
                ("price", "price"),
                ("price2", "price2"),
                ("trigger", "trigger"),
                ("leverage", "leverage"),
                ("reduce_only", "reduce_only"),
                ("stptype", "stptype"),
                ("oflags", "oflags"),
                ("timeinforce", "timeinforce"),
                ("starttm", "starttm"),
                ("expiretm", "expiretm"),
                ("close[ordertype]", "close"),
                ("close[price]", "close_price"),
                ("close[price2]", "close_price2"),
                ("deadline", "deadline"),
                ("validate", "validate"),
            ],
        ),
        "cancel_order" => (
            Post,
            "/0/private/CancelOrder",
            &[("txid", "txid"), ("cl_ord_id", "cl_ord_id")],
        ),
        "get_tradable_asset_pairs" => (
            Get,
            "/0/public/AssetPairs",
            &[
                ("pair", "pairs"),
                ("info", "info"),
                ("country_code", "country_code"),
                ("aclass_base", "aclass_base"),
            ],
        ),
        "get_asset_info" => (
            Get,
            "/0/public/Assets",
            &[("asset", "assets"), ("aclass", "aclass")],
        ),
        "get_ticker_information" => (Get, "/0/public/Ticker", &[("pair", "pair")]),
        "get_extended_balance" => (Post, "/0/private/BalanceEx", &[]),
        "get_api_key_info" => (Post, "/0/private/GetApiKeyInfo", &[]),
        "get_ohlc_data" => (
            Get,
            "/0/public/OHLC",
            &[
                ("pair", "pair"),
                ("interval", "interval"),
                ("since", "since"),
            ],
        ),
        "get_trades_history" => (
            Post,
            "/0/private/TradesHistory",
            &[
                ("type", "type"),
                ("trades", "trades"),
                ("start", "start"),
                ("end", "end_time"),
                ("ofs", "ofs"),
            ],
        ),
        "get_ledgers" => (
            Post,
            "/0/private/Ledgers",
            &[
                ("asset", "asset"),
                ("type", "type"),
                ("start", "start"),
                ("end", "end_time"),
                ("ofs", "ofs"),
            ],
        ),
        "get_withdraw_addresses" => (
            Post,
            "/0/private/WithdrawAddresses",
            &[("asset", "asset"), ("method", "method")],
        ),
        "get_withdraw_methods" => (Post, "/0/private/WithdrawMethods", &[("asset", "asset")]),
        "withdraw" => (
            Post,
            "/0/private/Withdraw",
            &[
                ("asset", "asset"),
                ("key", "key"),
                ("amount", "amount"),
                ("address", "address"),
            ],
        ),
        "get_earn_allocations" => (
            Post,
            "/0/private/Earn/Allocations",
            &[
                ("ascending", "ascending"),
                ("converted_asset", "converted_asset"),
                ("hide_zero_allocations", "hide_zero_allocations"),
            ],
        ),
        _ => return None,
    })
}

pub fn build(
    op: &str,
    params: &BTreeMap<String, Param>,
    creds: Option<&Credentials>,
) -> Result<Built, String> {
    let (method, path, fields) = layout(op).ok_or_else(|| format!("unknown Kraken op {op}"))?;
    let mut pairs = Vec::new();
    for (wire, name) in fields {
        let value = match params.get(*name) {
            None => None,
            Some(Param::Many(v)) if *name == "oflags" && v.is_empty() => None, // legacy: oflags.any? ? join : nil
            Some(Param::Many(v)) => Some(v.join(",")),
            Some(Param::One(s)) => Some(s.clone()),
        };
        if let Some(v) = value {
            pairs.push((wire.to_string(), v));
        }
    }
    Ok(match method {
        Method::Get => Built {
            method,
            path,
            pairs,
            body: None,
            headers: public_headers(),
        },
        Method::Post => {
            pairs.insert(
                0,
                (
                    "nonce".into(),
                    next_nonce(creds.map(|c| c.api_key.as_str())).to_string(),
                ),
            );
            let body = www_form(&pairs);
            let headers = private_headers(path, &body, creds);
            Built {
                method,
                path,
                pairs,
                body: Some(body),
                headers,
            }
        }
    })
}
