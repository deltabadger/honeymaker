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

use super::requests::Param;
use crate::semantics::truthy;
use std::collections::{BTreeMap, HashSet};

pub enum TradesStep<D> {
    Call(BTreeMap<String, Param>),
    Done(Vec<(Value, TradeAggregate<D>)>),
    Venue(Vec<Value>),
    Unreadable,
    /// The scan could not be completed; never a partial answer.
    Incomplete(String),
}

/// Honeymaker::Clients::Kraken#closed_orders_from_trades for Rust callers, made strict: it completes
/// (the distinct trades read reach Kraken's count) or it fails. Containers and records must have
/// Kraken's shape; where Ruby would stop early, trust a malformed container or skip a malformed
/// record and return what it had, this returns `Incomplete` or a shape error. The gem keeps its
/// own loop.
pub struct TradesPager {
    wanted: Vec<String>,
    start: Option<i64>,
    max_pages: u32,
    offset: u64,
    /// The largest `count` any page reported: the bar for completeness (R22).
    count: u64,
    pages: u32,
    seen: HashSet<String>,
    by_order: Vec<(Value, Vec<Value>)>,
}

impl TradesPager {
    pub fn new(order_ids: Vec<String>, start: Option<i64>, max_pages: u32) -> Self {
        Self {
            wanted: order_ids,
            start,
            max_pages,
            offset: 0,
            count: 0,
            pages: 0,
            seen: HashSet::new(),
            by_order: Vec::new(),
        }
    }

    /// No wanted ids: nothing to ask (legacy's `return Result::Success.new({}) if wanted.empty?`).
    pub fn start<D: Num>(&mut self) -> Result<TradesStep<D>, NormError<D::Error>> {
        if self.wanted.is_empty() {
            return Ok(TradesStep::Done(Vec::new()));
        }
        Ok(TradesStep::Call(self.params()))
    }

    fn params(&self) -> BTreeMap<String, Param> {
        let mut p = BTreeMap::from([("ofs".to_string(), Param::One(self.offset.to_string()))]);
        if let Some(s) = self.start {
            p.insert("start".to_string(), Param::One(s.to_string()));
        }
        p
    }

    fn done<D: Num>(&mut self) -> Result<TradesStep<D>, NormError<D::Error>> {
        std::mem::take(&mut self.by_order)
            .into_iter()
            .map(|(k, trades)| Ok((k, aggregate::<D>(&trades)?)))
            .collect::<Result<Vec<_>, _>>()
            .map(TradesStep::Done)
    }

    pub fn feed<D: Num>(&mut self, data: &Value) -> Result<TradesStep<D>, NormError<D::Error>> {
        let Some(obj) = data.as_object() else {
            return Ok(TradesStep::Unreadable);
        };
        if let Some(Value::Array(e)) = obj.get("error")
            && e.iter().any(|x| truthy(Some(x)))
        {
            return Ok(TradesStep::Venue(e.clone()));
        }
        // dig("result", "trades") raises unless result is nil or a Hash; nil is an unreadable page here.
        let result = match obj.get("result") {
            None | Some(Value::Null) => {
                return Ok(TradesStep::Incomplete(
                    "TradesHistory answered without a result".into(),
                ));
            }
            Some(Value::Object(m)) => m,
            Some(other) => return Err(format!("undefined method 'dig' for {other}").into()),
        };
        let count = result.get("count").and_then(Value::as_u64);
        let trades = match result.get("trades") {
            Some(Value::Object(m)) => m,
            other => {
                return Ok(TradesStep::Incomplete(format!(
                    "TradesHistory trades is not an object: {other:?}"
                )));
            }
        };
        // Every record must be an order's trade before any is filtered out: a malformed one is an
        // error, never a skipped row.
        let mut rows = Vec::with_capacity(trades.len());
        for (id, t) in trades {
            match t.get("ordertxid") {
                Some(Value::String(o)) if t.is_object() => rows.push((id, o.clone(), t)),
                _ => return Err(format!("trade {id} is not a Kraken trade: {t}").into()),
            }
        }
        for (id, otxid, t) in rows {
            // Offset paging can serve a trade twice (review ruling 3): count it once.
            if !self.seen.insert(id.clone()) {
                continue;
            }
            if self.wanted.contains(&otxid) {
                let key = Value::String(otxid);
                match self.by_order.iter_mut().find(|(k, _)| *k == key) {
                    Some((_, v)) => v.push(t.clone()),
                    None => self.by_order.push((key, vec![t.clone()])),
                }
            }
        }
        let Some(page_count) = count else {
            return Ok(TradesStep::Incomplete(format!(
                "TradesHistory count unreadable: {:?}",
                result.get("count")
            )));
        };
        // Held to the largest count seen: a shrinking count never lowers the bar (R22).
        self.count = self.count.max(page_count);
        let count = self.count;
        let distinct = self.seen.len() as u64;
        if distinct >= count {
            return self.done();
        }
        if trades.is_empty() {
            return Ok(TradesStep::Incomplete(format!(
                "TradesHistory ended after {distinct} of {count} trades"
            )));
        }
        self.pages += 1;
        self.offset += trades.len() as u64; // raw rows: the position in Kraken's list
        if self.offset >= count {
            return Ok(TradesStep::Incomplete(format!(
                "TradesHistory served {count} rows but only {distinct} distinct trades"
            )));
        }
        if self.pages >= self.max_pages {
            return Ok(TradesStep::Incomplete(format!(
                "more than {} TradesHistory pages",
                self.max_pages
            )));
        }
        Ok(TradesStep::Call(self.params()))
    }
}
