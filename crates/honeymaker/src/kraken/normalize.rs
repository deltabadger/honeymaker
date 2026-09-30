use crate::num::{NormError, Num};
use crate::semantics::{split_first, truthy};
use crate::{OrderStatus, OrderType, Side};
use serde_json::{Map, Value};
use std::borrow::Cow;

pub enum Finished<T> {
    Ok(T),
    Venue,
    Unreadable,
}

pub type R<T, D> = Result<Finished<T>, NormError<<D as Num>::Error>>;

const ASSET_MAP: &[(&str, &str)] = &[
    ("ZUSD", "USD"),
    ("ZEUR", "EUR"),
    ("ZGBP", "GBP"),
    ("ZJPY", "JPY"),
    ("ZCHF", "CHF"),
    ("ZCAD", "CAD"),
    ("ZAUD", "AUD"),
    ("XXBT", "XBT"),
    ("XETH", "ETH"),
    ("XXDG", "XDG"),
];

/// Legacy `BigDecimal(x.to_s)`.
pub fn dec<D: Num>(v: Option<&Value>) -> Result<D, NormError<D::Error>> {
    D::parse_to_s(v.unwrap_or(&Value::Null)).map_err(NormError::Num)
}

/// Not a Hash → unreadable (Task 5); `error.is_a?(Array) && error.any?` → venue.
fn envelope(data: &Value) -> Result<&Map<String, Value>, Finished<()>> {
    let Some(obj) = data.as_object() else {
        return Err(Finished::Unreadable);
    };
    if let Some(Value::Array(e)) = obj.get("error")
        && e.iter().any(|x| truthy(Some(x)))
    {
        return Err(Finished::Venue);
    }
    Ok(obj)
}

macro_rules! envelope_or_return {
    ($d:expr) => {
        match envelope($d) {
            Ok(o) => o,
            Err(Finished::Venue) => return Ok(Finished::Venue),
            Err(_) => return Ok(Finished::Unreadable),
        }
    };
}

/// `(result.data["result"] || {}).each do |key, value|`: Array elements are
/// destructured, with missing values becoming nil and extra values ignored.
fn result_entries(obj: &Map<String, Value>) -> Result<Vec<(Value, &Value)>, String> {
    match obj.get("result") {
        v if !truthy(v) => Ok(Vec::new()),
        Some(Value::Object(m)) => Ok(m
            .iter()
            .map(|(k, v)| (Value::String(k.clone()), v))
            .collect()),
        Some(Value::Array(a)) => Ok(a
            .iter()
            .map(|entry| match entry {
                Value::Array(pair) => (
                    pair.first().cloned().unwrap_or(Value::Null),
                    pair.get(1).unwrap_or(&Value::Null),
                ),
                other => (other.clone(), &Value::Null),
            })
            .collect()),
        Some(other) => Err(format!("result is not an object: {other}")), // legacy raises on these
        None => Ok(Vec::new()),
    }
}

/// Legacy string-key indexing accepts both Hash and String. String#[] returns
/// the requested substring when present, otherwise nil; other shapes raise.
fn string_fields<'a>(
    value: &'a Value,
    keys: &[&str],
) -> Result<Cow<'a, Map<String, Value>>, String> {
    match value {
        Value::Object(m) => Ok(Cow::Borrowed(m)),
        Value::String(s) => Ok(Cow::Owned(
            keys.iter()
                .filter(|key| s.contains(**key))
                .map(|key| (key.to_string(), Value::String(key.to_string())))
                .collect(),
        )),
        other => Err(format!("cannot index with a String: {other}")),
    }
}

pub struct KrakenBalance<D> {
    pub asset: Option<String>,
    pub free: D,
    pub locked: D,
}

pub fn balances<D: Num>(data: &Value) -> R<Vec<KrakenBalance<D>>, D> {
    let obj = envelope_or_return!(data);
    let mut out: Vec<KrakenBalance<D>> = Vec::new();
    for (symbol, balance) in result_entries(obj)? {
        let symbol = symbol
            .as_str()
            .ok_or_else(|| format!("symbol.split: {symbol}"))?;
        let first = split_first(symbol, '.');
        let asset = first.map(|f| {
            ASSET_MAP
                .iter()
                .find(|(k, _)| *k == f)
                .map(|(_, v)| v.to_string())
                .unwrap_or_else(|| f.to_string())
        });
        let bal = string_fields(balance, &["balance", "hold_trade"])?;
        let total: D = dec(bal.get("balance"))?;
        let hold = bal
            .get("hold_trade")
            .filter(|v| truthy(Some(v)))
            .cloned()
            .unwrap_or(Value::String("0".into()));
        let locked: D = dec(Some(&hold))?;
        let free = total.sub(&locked).map_err(NormError::Num)?;
        if free.is_zero().map_err(NormError::Num)? && locked.is_zero().map_err(NormError::Num)? {
            continue;
        }
        // A Ruby Hash keeps a repeated key's first position; the last value wins.
        match out.iter_mut().find(|b| b.asset == asset) {
            Some(b) => {
                b.free = free;
                b.locked = locked;
            }
            None => out.push(KrakenBalance {
                asset,
                free,
                locked,
            }),
        }
    }
    Ok(Finished::Ok(out))
}

pub struct NormalizedOrder<D> {
    pub order_id: Value,
    pub status: OrderStatus,
    pub side: Option<Side>,
    pub order_type: OrderType,
    pub price: Option<D>,
    pub amount: Option<D>,
    pub quote_amount: Option<D>,
    pub amount_exec: D,
    pub quote_amount_exec: D,
}

pub fn order_type(v: Option<&Value>) -> OrderType {
    match v.and_then(Value::as_str) {
        Some("market") => OrderType::Market,
        Some("limit") => OrderType::Limit,
        _ => OrderType::Unknown,
    }
}

fn status(v: Option<&Value>) -> OrderStatus {
    match v.and_then(Value::as_str) {
        Some("open") => OrderStatus::Open,
        Some("closed") => OrderStatus::Closed,
        Some("canceled") | Some("expired") => OrderStatus::Cancelled,
        _ => OrderStatus::Unknown,
    }
}

pub fn orders<D: Num>(data: &Value) -> R<Vec<NormalizedOrder<D>>, D> {
    let obj = envelope_or_return!(data);
    let empty = Map::new();
    let mut out = Vec::new();
    for (order_id, raw) in result_entries(obj)? {
        let raw = string_fields(
            raw,
            &[
                "descr", "status", "oflags", "vol", "vol_exec", "cost", "price",
            ],
        )?;
        let descr = match raw.get("descr") {
            v if !truthy(v) => Cow::Borrowed(&empty),
            Some(value) => string_fields(value, &["ordertype", "type", "price"])?,
            None => Cow::Borrowed(&empty),
        };
        let order_type = order_type(descr.get("ordertype"));
        let side = match descr.get("type") {
            None | Some(Value::Null) => None,
            // Ruby downcase does not apply contextual final-sigma mapping.
            Some(Value::String(s)) => Some(Side::from_venue(
                &s.chars().flat_map(char::to_lowercase).collect::<String>(),
            )),
            Some(other) => return Err(format!("descr.type: {other}").into()),
        };
        let viqc = match raw.get("oflags") {
            v if !truthy(v) => false,
            Some(Value::String(s)) => s.split(',').any(|f| f == "viqc"),
            Some(other) => return Err(format!("oflags: {other}").into()),
            None => false,
        };
        let vol: D = dec(raw.get("vol"))?;
        let (amount, quote_amount) = if viqc {
            (None, Some(vol))
        } else {
            (Some(vol), None)
        };
        let amount_exec: D = dec(raw.get("vol_exec"))?;
        let quote_amount_exec: D = dec(raw.get("cost"))?;
        let mut price: D = dec(raw.get("price"))?;
        if price.is_zero().map_err(NormError::Num)? && order_type == OrderType::Limit {
            price = dec(descr.get("price"))?;
        }
        let price = if price.is_zero().map_err(NormError::Num)? {
            None
        } else {
            Some(price)
        };
        out.push(NormalizedOrder {
            order_id,
            status: status(raw.get("status")),
            side,
            order_type,
            price,
            amount,
            quote_amount,
            amount_exec,
            quote_amount_exec,
        });
    }
    Ok(Finished::Ok(out))
}

/// `(result.data.dig("result", "txid") || []).first` as the raw JSON value.
pub fn add_order<D: Num>(data: &Value) -> R<Value, D> {
    let obj = envelope_or_return!(data);
    let txid = match obj.get("result") {
        None | Some(Value::Null) => None,
        Some(Value::Object(m)) => m.get("txid").filter(|v| truthy(Some(v))).cloned(),
        Some(other) => return Err(format!("result: {other}").into()),
    };
    Ok(Finished::Ok(match txid {
        None => Value::Null,
        Some(Value::Array(a)) => a.first().cloned().unwrap_or(Value::Null),
        Some(Value::Object(m)) => m
            .into_iter()
            .next()
            .map(|(k, v)| Value::Array(vec![Value::String(k), v]))
            .unwrap_or(Value::Null),
        Some(other) => return Err(format!("txid: {other}").into()),
    }))
}

pub struct Ticker {
    pub ticker: Value,
    pub base: Option<String>,
    pub quote: Option<String>,
    pub minimum_base_size: Value,
    /// REAL_COSTMIN[quote] || costmin || 0 as a raw value; the wrapper applies Ruby's `.to_s`
    /// (Float#to_s gives "5.0e-05" for XBT, which is part of the contract).
    pub minimum_quote_size: Value,
    pub base_decimals: Value,
    pub quote_decimals: Value,
    pub price_decimals: Value,
    pub trading_enabled: bool,
}

const REAL_COSTMIN: &[(&str, &str)] = &[
    // JSON literals of the Ruby constants (Integer vs Float kept)
    ("AUD", "10"),
    ("CAD", "5"),
    ("CHF", "5"),
    ("DAI", "5"),
    ("ETH", "0.002"),
    ("EUR", "0.5"),
    ("GBP", "5"),
    ("JPY", "500"),
    ("PYUSD", "5"),
    ("RLUSD", "5"),
    ("USD", "5"),
    ("USDC", "5"),
    ("USDQ", "5"),
    ("USDR", "5"),
    ("USDT", "5"),
    ("XBT", "0.00005"),
];

pub fn tickers(data: &Value) -> Result<Finished<Vec<Ticker>>, String> {
    let obj = data.as_object().ok_or("body is not an object")?;
    if let Some(Value::Array(e)) = obj.get("error")
        && e.iter().any(|x| truthy(Some(x)))
    {
        return Ok(Finished::Venue);
    }
    // Unlike the client, the exchange calls each_with_object without a fallback.
    if !matches!(obj.get("result"), Some(Value::Object(_) | Value::Array(_))) {
        return Err("result cannot be enumerated".into());
    }
    let mut seen: Vec<(String, Cow<'_, Map<String, Value>>)> = Vec::new();
    for (_, raw) in result_entries(obj)? {
        let info = string_fields(raw, &["wsname"])?;
        // Legacy: `next if wsname.nil? || wsname.empty?`. Anything else without #empty?/#split
        // (false, 1) raises there and fails the WHOLE catalogue; never silently drop the pair.
        let ws = match info.get("wsname") {
            None | Some(Value::Null) => continue,
            Some(Value::String(w)) if w.is_empty() => continue,
            Some(Value::String(w)) => w.as_str(),
            Some(Value::Array(a)) if a.is_empty() => continue, // [].empty? is true in Ruby too
            Some(Value::Object(m)) if m.is_empty() => continue,
            Some(other) => return Err(format!("wsname: {other}")),
        };
        if !seen.iter().any(|(w, _)| w == ws) {
            // A String containing "wsname" passes indexing but later lacks Hash#key?.
            if !raw.is_object() {
                return Err("pair info has no key? method".into());
            }
            seen.push((ws.to_string(), info));
        }
    }
    let get = |info: &Map<String, Value>, k: &str| info.get(k).cloned().unwrap_or(Value::Null);
    Ok(Finished::Ok(
        seen.into_iter()
            .map(|(ws, info)| {
                // String#split drops trailing empty fields, including all fields in "/".
                let trimmed = ws.trim_end_matches('/');
                let mut parts = trimmed.split('/').filter(|_| !trimmed.is_empty());
                let base = parts.next().map(str::to_string);
                let quote = parts.next().map(str::to_string);
                let costmin = quote
                    .as_deref()
                    .and_then(|q| REAL_COSTMIN.iter().find(|(k, _)| *k == q))
                    .map(|(_, lit)| serde_json::from_str::<Value>(lit).expect("literal"))
                    .or_else(|| info.get("costmin").filter(|v| truthy(Some(v))).cloned())
                    .unwrap_or(Value::from(0));
                let trading_enabled =
                    if info.get("aclass_base").and_then(Value::as_str) == Some("tokenized_asset") {
                        false
                    } else {
                        info.get("status")
                            .map(|s| s.as_str() == Some("online"))
                            .unwrap_or(true)
                    };
                Ticker {
                    ticker: get(&info, "altname"),
                    base,
                    quote,
                    minimum_base_size: get(&info, "ordermin"),
                    minimum_quote_size: costmin,
                    base_decimals: get(&info, "lot_decimals"),
                    quote_decimals: get(&info, "cost_decimals"),
                    price_decimals: get(&info, "pair_decimals"),
                    trading_enabled,
                }
            })
            .collect(),
    ))
}

/// Legacy: raise error.first if errors; first result entry; BigDecimal(data["b"][0]) (no to_s).
pub fn bid_ask<D: Num>(data: &Value) -> R<(D, D), D> {
    let obj = data.as_object().ok_or("body is not an object")?;
    if let Some(Value::Array(e)) = obj.get("error")
        && e.iter().any(|x| truthy(Some(x)))
    {
        return Ok(Finished::Venue);
    }
    let first = match obj.get("result") {
        Some(Value::Object(m)) => m.values().next(),
        Some(Value::Array(a)) => match a.first() {
            Some(Value::Array(pair)) => pair.get(1),
            _ => None,
        },
        _ => None,
    }
    .ok_or("no ticker in result")?;
    let first = string_fields(first, &["b", "a"])?;
    let side = |k: &str| -> Result<D, NormError<D::Error>> {
        // Ruby [0]: array entry, first character, integer bit, or absent Hash key.
        let value = match first.get(k) {
            Some(Value::Array(a)) => a.first().cloned().unwrap_or(Value::Null),
            Some(Value::String(s)) => s
                .chars()
                .next()
                .map(|c| Value::String(c.to_string()))
                .unwrap_or(Value::Null),
            Some(Value::Object(_)) => Value::Null,
            Some(Value::Number(n)) => {
                let text = n.to_string();
                if text.contains(['.', 'e', 'E']) {
                    return Err(format!("{k} has no [] method").into());
                }
                Value::from((text.as_bytes().last().unwrap() - b'0') % 2)
            }
            _ => return Err(format!("{k}[0] missing").into()),
        };
        D::parse_json(&value).map_err(NormError::Num)
    };
    Ok(Finished::Ok((side("b")?, side("a")?)))
}

/// Exchanges::Kraken::ERROR_PATTERNS, first match wins. Ruby's \w and \S are ASCII here.
pub fn classify_error(message: &str) -> Option<(&'static str, Vec<(&'static str, String)>)> {
    static RES: std::sync::OnceLock<Vec<(&'static str, regex::Regex)>> = std::sync::OnceLock::new();
    let res = RES.get_or_init(|| vec![
        ("regional_restriction", regex::Regex::new(r"\AEAccount:Invalid permissions:(?P<asset>[^ \t\r\n\x0B\x0C]+) trading restricted for (?P<country>[A-Za-z0-9_]+)\.?\z").unwrap()),
        ("transient_nonce", regex::Regex::new(r"EAPI:Invalid nonce").unwrap()),
        ("transient_unavailable", regex::Regex::new(r"EGeneral:Internal error|EService:(?:Unavailable|Busy|Deadline elapsed)").unwrap()),
    ]);
    for (code, re) in res {
        if let Some(c) = re.captures(message) {
            let caps = ["asset", "country"]
                .iter()
                .filter_map(|n| c.name(n).map(|m| (*n, m.as_str().to_string())))
                .collect();
            return Some((code, caps));
        }
    }
    None
}
