use super::normalize::{dec, order_type};
use crate::OrderType;
use crate::num::{NormError, Num};
use serde_json::Value;

pub struct TradeAggregate<D> {
    pub side: Option<Value>, // first["type"]&.to_sym (not downcased)
    pub order_type: OrderType,
    pub vol: D,
    pub cost: D,
    pub fee: D,
    pub price: Option<D>, // vol.zero? ? nil : cost / vol
}

/// Per-order executed aggregate over its (non-empty) trades, as legacy `aggregate_trades`.
pub fn aggregate<D: Num>(trades: &[Value]) -> Result<TradeAggregate<D>, NormError<D::Error>> {
    let first = trades.first().ok_or("no trades")?;
    let first = first.as_object().ok_or_else(|| format!("trade: {first}"))?;
    // Array#sum starts from Integer 0: 0 + BigDecimal("-0") is +0.0, so start from "0" too.
    let sum = |f: &str| -> Result<D, NormError<D::Error>> {
        let mut acc = D::parse("0").map_err(NormError::Num)?;
        for t in trades {
            acc = acc.add(&dec(t.get(f))?).map_err(NormError::Num)?;
        }
        Ok(acc)
    };
    let (vol, cost, fee) = (sum("vol")?, sum("cost")?, sum("fee")?);
    let price = if vol.is_zero().map_err(NormError::Num)? {
        None
    } else {
        Some(cost.div(&vol).map_err(NormError::Num)?)
    };
    let side = match first.get("type") {
        None | Some(Value::Null) => None,
        Some(v) if crate::semantics::is_string(v) => {
            Some(D::string_op(v, crate::semantics::StringOp::Symbol).map_err(NormError::Num)?)
        }
        Some(other) => return Err(format!("type.to_sym: {other}").into()), // false/1 have no to_sym
    };
    Ok(TradeAggregate {
        side,
        order_type: order_type(first.get("ordertype")),
        vol,
        cost,
        fee,
        price,
    })
}
