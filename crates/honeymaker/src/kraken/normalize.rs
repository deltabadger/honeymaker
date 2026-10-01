use crate::num::{NormError, Num};
use crate::semantics::{StringOp, is_string, object_key, string_eq, truthy};
use crate::{OrderStatus, OrderType};
use serde_json::{Map, Value};
use std::borrow::Cow;

pub enum Finished<T> {
    Ok(T),
    /// Kraken answered with a truthy element in `error`: the whole array, verbatim.
    Venue(Vec<Value>),
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

/// Not a Hash → unreadable; `error.is_a?(Array) && error.any?` → venue, carrying the array.
fn envelope(data: &Value) -> Result<&Map<String, Value>, Finished<()>> {
    let Some(obj) = data.as_object() else {
        return Err(Finished::Unreadable);
    };
    if let Some(Value::Array(e)) = obj.get("error")
        && e.iter().any(|x| truthy(Some(x)))
    {
        return Err(Finished::Venue(e.clone()));
    }
    Ok(obj)
}

macro_rules! envelope_or_return {
    ($d:expr) => {
        match envelope($d) {
            Ok(o) => o,
            Err(Finished::Venue(e)) => return Ok(Finished::Venue(e)),
            Err(_) => return Ok(Finished::Unreadable),
        }
    };
}

/// `(result.data["result"] || {}).each do |key, value|`: Array elements are
/// destructured, with missing values becoming nil and extra values ignored.
fn result_entries(obj: &Map<String, Value>) -> Result<Vec<(Value, &Value)>, String> {
    match obj.get("result") {
        v if !truthy(v) => Ok(Vec::new()),
        Some(v) if is_string(v) => Err(format!("result is not an object: {v}")),
        Some(Value::Object(m)) => Ok(m.iter().map(|(k, v)| (object_key(k), v)).collect()),
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
fn string_fields<'a, D: Num>(
    value: &'a Value,
    keys: &[&str],
) -> Result<Cow<'a, Map<String, Value>>, NormError<D::Error>> {
    if is_string(value) {
        let mut fields = Map::new();
        for key in keys {
            let found = D::string_op(value, StringOp::Index(key)).map_err(NormError::Num)?;
            if !found.is_null() {
                fields.insert(key.to_string(), found);
            }
        }
        return Ok(Cow::Owned(fields));
    }
    match value {
        Value::Object(m) => Ok(Cow::Borrowed(m)),
        other => Err(format!("cannot index with a String: {other}").into()),
    }
}

pub struct KrakenBalance<D> {
    pub asset: Value,
    pub free: D,
    pub locked: D,
}

pub fn balances<D: Num>(data: &Value) -> R<Vec<KrakenBalance<D>>, D> {
    let obj = envelope_or_return!(data);
    let mut out: Vec<KrakenBalance<D>> = Vec::new();
    for (symbol, balance) in result_entries(obj)? {
        if !is_string(&symbol) {
            return Err(format!("symbol.split: {symbol}").into());
        }
        let parts = D::string_op(&symbol, StringOp::Split(".")).map_err(NormError::Num)?;
        let first = parts[0].clone();
        let asset = ASSET_MAP
            .iter()
            .find(|(k, _)| string_eq(&first, k))
            .map(|(_, v)| Value::from(*v))
            .unwrap_or(first);
        let bal = string_fields::<D>(balance, &["balance", "hold_trade"])?;
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

/// deltabadger's Exchanges::Kraken#get_balances for one asset: each code is split at "." and
/// mapped (ZEUR → EUR, XXBT → XBT); free = balance − hold_trade; a later entry for the same asset
/// replaces an earlier one (Hash assignment), zeros included; an absent asset is 0. Rails digs
/// result and the matching entry's hold_trade with dig_or_raise, so nil there is an error, not 0
/// (false raises too, on `.each` / `.to_d`).
pub fn free_balance<D: Num>(data: &Value, symbol: &str) -> R<D, D> {
    let obj = envelope_or_return!(data);
    if !truthy(obj.get("result")) {
        return Err("result: missing".to_string().into());
    }
    let mut free = D::parse("0").map_err(NormError::Num)?;
    for (code, balance) in result_entries(obj)? {
        let Some(code) = code.as_str() else {
            return Err(format!("asset code: {code}").into());
        };
        let base = code.split('.').next().unwrap_or(code);
        let name = ASSET_MAP
            .iter()
            .find(|(k, _)| *k == base)
            .map(|(_, v)| *v)
            .unwrap_or(base);
        if name != symbol {
            continue;
        }
        let b = string_fields::<D>(balance, &["balance", "hold_trade"])?;
        let total: D = dec(b.get("balance"))?;
        let hold = b.get("hold_trade").filter(|v| truthy(Some(v)));
        let Some(hold) = hold else {
            return Err(format!("hold_trade: missing for {code}").into());
        };
        free = total.sub(&dec::<D>(Some(hold))?).map_err(NormError::Num)?;
    }
    Ok(Finished::Ok(free))
}

pub struct NormalizedOrder<D> {
    pub order_id: Value,
    pub status: OrderStatus,
    pub side: Option<Value>,
    pub order_type: OrderType,
    pub price: Option<D>,
    pub amount: Option<D>,
    pub quote_amount: Option<D>,
    pub amount_exec: D,
    pub quote_amount_exec: D,
    /// Kraken's client order id and user reference, as sent (absent or null → None).
    pub cl_ord_id: Option<Value>,
    pub userref: Option<Value>,
}

pub fn order_type(v: Option<&Value>) -> OrderType {
    match v {
        Some(v) if string_eq(v, "market") => OrderType::Market,
        Some(v) if string_eq(v, "limit") => OrderType::Limit,
        _ => OrderType::Unknown,
    }
}

fn status(v: Option<&Value>) -> OrderStatus {
    match v {
        Some(v) if string_eq(v, "open") => OrderStatus::Open,
        Some(v) if string_eq(v, "closed") => OrderStatus::Closed,
        Some(v) if string_eq(v, "canceled") || string_eq(v, "expired") => OrderStatus::Cancelled,
        _ => OrderStatus::Unknown,
    }
}

pub fn orders<D: Num>(data: &Value) -> R<Vec<NormalizedOrder<D>>, D> {
    let obj = envelope_or_return!(data);
    Ok(Finished::Ok(order_entries::<D>(result_entries(obj)?)?))
}

fn order_entries<D: Num>(
    entries: Vec<(Value, &Value)>,
) -> Result<Vec<NormalizedOrder<D>>, NormError<D::Error>> {
    let empty = Map::new();
    let mut out = Vec::new();
    for (order_id, raw) in entries {
        let raw = string_fields::<D>(
            raw,
            &[
                "descr",
                "status",
                "oflags",
                "vol",
                "vol_exec",
                "cost",
                "price",
                "cl_ord_id",
                "userref",
            ],
        )?;
        let descr = match raw.get("descr") {
            v if !truthy(v) => Cow::Borrowed(&empty),
            Some(value) => string_fields::<D>(value, &["ordertype", "type", "price"])?,
            None => Cow::Borrowed(&empty),
        };
        let order_type = order_type(descr.get("ordertype"));
        let side = match descr.get("type") {
            None | Some(Value::Null) => None,
            Some(v) if is_string(v) => {
                Some(D::string_op(v, StringOp::DowncaseSymbol).map_err(NormError::Num)?)
            }
            Some(other) => return Err(format!("descr.type: {other}").into()),
        };
        let viqc = match raw.get("oflags") {
            v if !truthy(v) => false,
            Some(v) if is_string(v) => D::string_op(v, StringOp::Split(","))
                .map_err(NormError::Num)?
                .as_array()
                .unwrap()
                .iter()
                .any(|f| string_eq(f, "viqc")),
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
            cl_ord_id: raw.get("cl_ord_id").filter(|v| !v.is_null()).cloned(),
            userref: raw.get("userref").filter(|v| !v.is_null()).cloned(),
        });
    }
    Ok(out)
}

/// OpenOrders (`result.open`) and ClosedOrders (`result.closed` + `result.count`): QueryOrders'
/// order shape under one more key. Both containers must be objects: a missing or null one is an
/// unreadable answer, never "no orders" (a lookup would otherwise conclude absence from it).
/// The count is returned raw.
pub fn listed_orders<D: Num>(
    data: &Value,
    key: &str,
) -> R<(Vec<NormalizedOrder<D>>, Option<Value>), D> {
    let obj = envelope_or_return!(data);
    let result = match obj.get("result") {
        Some(Value::Object(m)) => m,
        other => return Err(format!("result is not an object: {other:?}").into()),
    };
    let entries: Vec<(Value, &Value)> = match result.get(key) {
        Some(Value::Object(m)) => m.iter().map(|(k, v)| (object_key(k), v)).collect(),
        other => return Err(format!("{key} is not an object: {other:?}").into()),
    };
    Ok(Finished::Ok((
        order_entries::<D>(entries)?,
        result.get("count").cloned(),
    )))
}

pub struct TickerPrices<D> {
    pub bid: D,
    pub ask: D,
    pub last: D,
}

/// deltabadger's Exchanges::Kraken#get_ticker_information: the first result entry's `b[0]`,
/// `a[0]` and `c[0]` (last trade closed). None when the result names no pair.
pub fn ticker_prices<D: Num>(data: &Value) -> R<Option<TickerPrices<D>>, D> {
    let obj = envelope_or_return!(data);
    let Some((_, info)) = result_entries(obj)?.into_iter().next() else {
        return Ok(Finished::Ok(None));
    };
    let info = info
        .as_object()
        .ok_or_else(|| format!("ticker entry is not an object: {info}"))?;
    let first = |k: &str| -> Result<D, NormError<D::Error>> {
        match info.get(k) {
            Some(Value::Array(a)) => dec(a.first()),
            other => Err(format!("{k}[0] missing: {other:?}").into()),
        }
    };
    Ok(Finished::Ok(Some(TickerPrices {
        bid: first("b")?,
        ask: first("a")?,
        last: first("c")?,
    })))
}

/// `(result.data.dig("result", "txid") || []).first` as the raw JSON value.
pub fn add_order<D: Num>(data: &Value) -> R<Value, D> {
    let obj = envelope_or_return!(data);
    let txid = match obj.get("result") {
        None | Some(Value::Null) => None,
        Some(v) if is_string(v) => return Err(format!("result: {v}").into()),
        Some(Value::Object(m)) => m.get("txid").filter(|v| truthy(Some(v))).cloned(),
        Some(other) => return Err(format!("result: {other}").into()),
    };
    Ok(Finished::Ok(match txid {
        None => Value::Null,
        Some(Value::Array(a)) => a.first().cloned().unwrap_or(Value::Null),
        Some(v) if is_string(&v) => return Err(format!("txid: {v}").into()),
        Some(Value::Object(m)) => m
            .into_iter()
            .next()
            .map(|(k, v)| Value::Array(vec![object_key(&k), v]))
            .unwrap_or(Value::Null),
        Some(other) => return Err(format!("txid: {other}").into()),
    }))
}

pub struct Ticker {
    pub ticker: Value,
    pub base: Value,
    pub quote: Value,
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

pub fn tickers<D: Num>(data: &Value) -> R<Vec<Ticker>, D> {
    let obj = data.as_object().ok_or("body is not an object")?;
    if let Some(Value::Array(e)) = obj.get("error")
        && e.iter().any(|x| truthy(Some(x)))
    {
        return Ok(Finished::Venue(e.clone()));
    }
    // Unlike the client, the exchange calls each_with_object without a fallback.
    if !matches!(obj.get("result"), Some(Value::Object(_) | Value::Array(_))) {
        return Err("result cannot be enumerated".into());
    }
    let mut seen: Vec<(Value, Cow<'_, Map<String, Value>>)> = Vec::new();
    for (_, raw) in result_entries(obj)? {
        let info = string_fields::<D>(raw, &["wsname"])?;
        // Legacy: `next if wsname.nil? || wsname.empty?`. Anything else without #empty?/#split
        // (false, 1) raises there and fails the WHOLE catalogue; never silently drop the pair.
        let ws = match info.get("wsname") {
            None | Some(Value::Null) => continue,
            Some(w) if is_string(w) && string_eq(w, "") => continue,
            Some(v) if is_string(v) => v,
            Some(Value::Array(a)) if a.is_empty() => continue, // [].empty? is true in Ruby too
            Some(Value::Object(m)) if m.is_empty() => continue,
            Some(other) => return Err(format!("wsname: {other}").into()),
        };
        if !seen.iter().any(|(w, _)| w == ws) {
            // A String containing "wsname" passes indexing but later lacks Hash#key?.
            if !raw.is_object() || is_string(raw) {
                return Err("pair info has no key? method".into());
            }
            seen.push((ws.clone(), info));
        }
    }
    let get = |info: &Map<String, Value>, k: &str| info.get(k).cloned().unwrap_or(Value::Null);
    Ok(Finished::Ok(
        seen.into_iter()
            .map(|(ws, info)| {
                let parts = D::string_op(&ws, StringOp::Split("/")).map_err(NormError::Num)?;
                let base = parts[0].clone();
                let quote = parts[1].clone();
                let costmin = REAL_COSTMIN
                    .iter()
                    .find(|(k, _)| string_eq(&quote, k))
                    .map(|(_, lit)| serde_json::from_str::<Value>(lit).expect("literal"))
                    .or_else(|| info.get("costmin").filter(|v| truthy(Some(v))).cloned())
                    .unwrap_or(Value::from(0));
                let trading_enabled = if info
                    .get("aclass_base")
                    .is_some_and(|v| string_eq(v, "tokenized_asset"))
                {
                    false
                } else {
                    info.get("status")
                        .map(|s| string_eq(s, "online"))
                        .unwrap_or(true)
                };
                Ok(Ticker {
                    ticker: get(&info, "altname"),
                    base,
                    quote,
                    minimum_base_size: get(&info, "ordermin"),
                    minimum_quote_size: costmin,
                    base_decimals: get(&info, "lot_decimals"),
                    quote_decimals: get(&info, "cost_decimals"),
                    price_decimals: get(&info, "pair_decimals"),
                    trading_enabled,
                })
            })
            .collect::<Result<Vec<_>, NormError<D::Error>>>()?,
    ))
}

/// Legacy: raise error.first if errors; first result entry; BigDecimal(data["b"][0]) (no to_s).
pub fn bid_ask<D: Num>(data: &Value) -> R<(D, D), D> {
    let obj = data.as_object().ok_or("body is not an object")?;
    if let Some(Value::Array(e)) = obj.get("error")
        && e.iter().any(|x| truthy(Some(x)))
    {
        return Ok(Finished::Venue(e.clone()));
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
    let first = string_fields::<D>(first, &["b", "a"])?;
    let side = |k: &str| -> Result<D, NormError<D::Error>> {
        // Ruby [0]: array entry, first character, integer bit, or absent Hash key.
        let value = match first.get(k) {
            Some(Value::Array(a)) => a.first().cloned().unwrap_or(Value::Null),
            Some(v) if is_string(v) => D::string_op(v, StringOp::First).map_err(NormError::Num)?,
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
pub type ClassifiedError = (&'static str, Vec<(&'static str, Vec<u8>)>);
pub fn classify_error(message: &[u8]) -> Option<ClassifiedError> {
    static RES: std::sync::OnceLock<Vec<(&'static str, regex::bytes::Regex)>> =
        std::sync::OnceLock::new();
    let res = RES.get_or_init(|| vec![
        ("regional_restriction", regex::bytes::Regex::new(r"(?-u)\AEAccount:Invalid permissions:(?P<asset>[^ \t\r\n\x0B\x0C]+) trading restricted for (?P<country>[A-Za-z0-9_]+)\.?\z").unwrap()),
        ("transient_nonce", regex::bytes::Regex::new(r"EAPI:Invalid nonce").unwrap()),
        ("transient_unavailable", regex::bytes::Regex::new(r"EGeneral:Internal error|EService:(?:Unavailable|Busy|Deadline elapsed)").unwrap()),
    ]);
    for (code, re) in res {
        if let Some(c) = re.captures(message) {
            let caps = ["asset", "country"]
                .iter()
                .filter_map(|n| c.name(n).map(|m| (*n, m.as_bytes().to_vec())))
                .collect();
            return Some((code, caps));
        }
    }
    None
}
