use crate::num::{NormError, Num};
use crate::semantics::{split_first, truthy};
use crate::{OrderStatus, OrderType, Side};
use serde_json::{Map, Value};

pub enum Finished<T> {
    Ok(T),
    Venue,
    Unreadable,
    Invalid,
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

/// `(result.data["result"] || {}).each`.
fn result_entries(obj: &Map<String, Value>) -> Result<Vec<(&String, &Value)>, String> {
    match obj.get("result") {
        v if !truthy(v) => Ok(Vec::new()),
        Some(Value::Object(m)) => Ok(m.iter().collect()),
        Some(Value::Array(a)) if a.is_empty() => Ok(Vec::new()), // [].each yields nothing: Success({})
        Some(other) => Err(format!("result is not an object: {other}")), // legacy raises on these
        None => Ok(Vec::new()),
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
        let first = split_first(symbol, '.');
        let asset = first.map(|f| {
            ASSET_MAP
                .iter()
                .find(|(k, _)| *k == f)
                .map(|(_, v)| v.to_string())
                .unwrap_or_else(|| f.to_string())
        });
        let bal = balance
            .as_object()
            .ok_or_else(|| format!("balance entry: {balance}"))?;
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
    pub order_id: String,
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
        let raw = raw
            .as_object()
            .ok_or_else(|| format!("order {order_id}: {raw}"))?;
        let descr = match raw.get("descr") {
            v if !truthy(v) => &empty,
            Some(Value::Object(m)) => m,
            Some(other) => return Err(format!("descr: {other}").into()),
            None => &empty,
        };
        let order_type = order_type(descr.get("ordertype"));
        let side = match descr.get("type") {
            None | Some(Value::Null) => None,
            Some(Value::String(s)) => Some(Side::from_venue(&s.to_lowercase())),
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
            order_id: order_id.clone(),
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
        Some(other) => return Err(format!("txid: {other}").into()),
    }))
}

/// Legacy validate: `errors.is_a?(Array) && errors.none?`.
pub fn validate<D: Num>(data: &Value) -> R<bool, D> {
    Ok(match data.get("error") {
        Some(Value::Array(e)) if !e.iter().any(|x| truthy(Some(x))) => Finished::Ok(true),
        _ => Finished::Invalid,
    })
}
