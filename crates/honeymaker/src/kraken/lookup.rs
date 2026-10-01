//! Find an order by client order id: OpenOrders, then every ClosedOrders page since `start`.
//! `Absent` comes only from a complete scan; any other end is a refusal, an unreadable page or
//! `Incomplete`, never a partial answer reported as complete.
//!
//! Why this order cannot miss an order placed before the scan began: if it is open when
//! OpenOrders is read, it is found there. Otherwise it closed earlier and sits in the closed list,
//! which is newest first, so orders closing during the scan only push it to a higher offset, onto a
//! page not yet read. Paging can re-read an order; it cannot skip one. Because a re-read row is
//! not coverage, absence needs the distinct ids read to reach Kraken's count.
use super::normalize::{Finished, NormalizedOrder, listed_orders};
use super::requests::Param;
use crate::num::{NormError, Num};
use crate::semantics::{self, string_eq};
use serde_json::Value;
use std::collections::{BTreeMap, HashSet};

/// Kraken answers 50 closed orders a page; with its `cl_ord_id` filter honoured, one page answers.
/// ponytail: no pacing between pages. A scan this long trips Kraken's rate limit and ends as a
/// refusal, which callers treat as "not known yet". Add pacing if a live account ever needs it.
pub const MAX_CLOSED_PAGES: u32 = 50;

// Keep the specified public API: Found returns the normalized order by value.
#[allow(clippy::large_enum_variant)]
pub enum Step<D> {
    Call(&'static str, BTreeMap<String, Param>),
    Found(NormalizedOrder<D>),
    Absent,
    Venue(Vec<Value>),
    Unreadable,
    Incomplete(String),
}

pub struct ClientIdLookup {
    cl_ord_id: String,
    start: i64,
    closed: bool,
    /// Raw rows served so far: the `ofs` of the next request.
    ofs: u64,
    pages: u32,
    /// Distinct closed-order ids read: absence needs these to cover Kraken's count.
    seen: HashSet<String>,
    /// The largest `count` any page reported: the bar for absence (R22).
    count: u64,
}

impl ClientIdLookup {
    pub fn new(cl_ord_id: &str, start: i64) -> Self {
        Self {
            cl_ord_id: cl_ord_id.to_string(),
            start,
            closed: false,
            ofs: 0,
            pages: 0,
            seen: HashSet::new(),
            count: 0,
        }
    }

    pub fn first<D>(&self) -> Step<D> {
        Step::Call(
            "open_orders",
            BTreeMap::from([("cl_ord_id".to_string(), Param::One(self.cl_ord_id.clone()))]),
        )
    }

    fn closed_page<D>(&self) -> Step<D> {
        Step::Call(
            "closed_orders",
            BTreeMap::from([
                ("cl_ord_id".to_string(), Param::One(self.cl_ord_id.clone())),
                ("start".to_string(), Param::One(self.start.to_string())),
                ("ofs".to_string(), Param::One(self.ofs.to_string())),
            ]),
        )
    }

    /// Feed the parsed body answering the last `Call`.
    pub fn feed<D: Num>(&mut self, data: &Value) -> Result<Step<D>, NormError<D::Error>> {
        let key = if self.closed { "closed" } else { "open" };
        let (orders, count) = match listed_orders::<D>(data, key)? {
            Finished::Ok(x) => x,
            Finished::Venue(e) => return Ok(Step::Venue(e)),
            Finished::Unreadable => return Ok(Step::Unreadable),
        };
        let n = orders.len() as u64;
        let ids: Vec<String> = orders
            .iter()
            .map(|o| semantics::to_s(&o.order_id).unwrap_or_else(|_| o.order_id.to_string()))
            .collect();
        if let Some(o) = orders.into_iter().find(|o| {
            o.cl_ord_id
                .as_ref()
                .is_some_and(|c| string_eq(c, &self.cl_ord_id))
        }) {
            return Ok(Step::Found(o));
        }
        if !self.closed {
            self.closed = true;
            return Ok(self.closed_page());
        }
        let Some(page_total) = count.as_ref().and_then(Value::as_u64) else {
            return Ok(Step::Incomplete(format!(
                "ClosedOrders count unreadable: {count:?}"
            )));
        };
        // Held to the largest count seen: a shrinking count never lowers the bar (R22).
        self.count = self.count.max(page_total);
        let total = self.count;
        self.seen.extend(ids);
        self.pages += 1;
        self.ofs += n;
        let distinct = self.seen.len() as u64;
        // Absence needs every distinct closed order read; a duplicate row is not coverage
        // (review round 3, ruling 1).
        if distinct >= total {
            return Ok(Step::Absent);
        }
        if n == 0 {
            return Ok(Step::Incomplete(format!(
                "ClosedOrders page {} was empty after {distinct} of {total} orders",
                self.pages
            )));
        }
        if self.ofs >= total {
            return Ok(Step::Incomplete(format!(
                "ClosedOrders served {total} rows but only {distinct} distinct orders"
            )));
        }
        if self.pages >= MAX_CLOSED_PAGES {
            return Ok(Step::Incomplete(format!(
                "more than {MAX_CLOSED_PAGES} ClosedOrders pages since {}",
                self.start
            )));
        }
        Ok(self.closed_page())
    }
}
