//! Kraken for Rust callers: the calls deltabadger's engine makes, with its `Venue` trait's
//! signatures and error classes. Requests, signing, nonces and normalizers are the core's.
use crate::transport::{Failure, Reply};
use serde_json::Value;

pub const UNREADABLE: &str = "Kraken: unreadable response";

#[derive(Clone, Debug, PartialEq)]
pub enum VenueError {
    /// Kraken answered and refused: its `error` array verbatim, or an HTTP answer Rails treats as
    /// definitive (e.g. 4xx). `add_order` applies Rails' placement rules via `placement()`:
    /// transient/network/HTTP 5xx strings become `Ambiguous`; recvWindow and definitive refusals
    /// remain `Rejected`. Every other call returns Kraken's error array as `Rejected`, leaving
    /// interpretation to the caller.
    Rejected(Vec<String>),
    /// The request may have reached Kraken.
    Ambiguous(String),
    /// Nothing reached Kraken.
    Transient(String),
}

/// The transport/status part of Exchange#ambiguous_placement_error?: `add_order` additionally
/// applies Rails' text rules via `placement()` (transient/network/HTTP 5xx → `Ambiguous`;
/// recvWindow and definitive refusals → `Rejected`). Every other call returns Kraken's error
/// array as `Rejected` and leaves interpretation to the caller.
/// A transport failure is decided by its cause alone; an HTTP answer by its
/// status (≥ 500 or 2xx: ambiguous; anything else: a definitive rejection); a 2xx body that is
/// not a JSON object is unreadable, hence ambiguous.
#[doc(hidden)]
pub fn outcome(reply: Result<Reply, Failure>) -> Result<Value, VenueError> {
    match reply {
        Err(f) if f.pre_transmission() => Err(VenueError::Transient(f.message)),
        Err(f) => Err(VenueError::Ambiguous(f.message)),
        Ok(Reply::Status { status, message }) if status >= 500 || (200..300).contains(&status) => {
            Err(VenueError::Ambiguous(message))
        }
        Ok(Reply::Status { message, .. }) => Err(VenueError::Rejected(vec![message])),
        Ok(Reply::Parsed(v)) if v.is_object() => Ok(v),
        Ok(_) => Err(VenueError::Ambiguous(UNREADABLE.into())),
    }
}

use crate::transport::{ConfigError, Request, Timeouts, Transport};
use bigdecimal::BigDecimal;
use chrono::{DateTime, SecondsFormat, Utc};
use honeymaker::encode::www_form;
use honeymaker::kraken::lookup::{ClientIdLookup, Step};
use honeymaker::kraken::normalize::{self, Finished, NormalizedOrder};
use honeymaker::kraken::requests::{self, Method, Param};
use honeymaker::num::NormError;
use honeymaker::{OrderStatus as CoreStatus, OrderType, semantics};
use std::collections::BTreeMap;
use std::sync::Arc;

pub use honeymaker::kraken::sign::Credentials;

pub const DEFAULT_URL: &str = "https://api.kraken.com";
pub const DEFAULT_USER_AGENT: &str = "Honeymaker Ruby";

#[derive(Clone, Debug, PartialEq)]
pub struct Prices {
    pub bid: BigDecimal,
    pub ask: BigDecimal,
    pub last: BigDecimal,
}

#[derive(Clone, Debug, PartialEq)]
pub enum OrderKind {
    Market,
    Limit { price: String },
}

/// A buy (the engine only buys), formatted as the wire expects: volume and price already floored,
/// in `to_s('F')` form.
#[derive(Clone, Debug, PartialEq)]
pub struct NewOrder {
    pub pair: String,
    pub kind: OrderKind,
    pub volume: String,
    /// Kraken `oflags=viqc`: the volume is in quote currency.
    pub quote_volume: bool,
    pub cl_ord_id: String,
    pub deadline: DateTime<Utc>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum OrderStatus {
    Unknown,
    Open,
    Closed,
    Cancelled,
}

/// An order as deltabadger's Exchanges::Kraken#parse_order_data reports it.
#[derive(Clone, Debug, PartialEq)]
pub struct OrderState {
    pub txid: String,
    pub status: OrderStatus,
    pub price: Option<BigDecimal>,
    pub amount: Option<BigDecimal>,
    pub quote_amount: Option<BigDecimal>,
    pub amount_exec: BigDecimal,
    pub quote_amount_exec: BigDecimal,
    pub limit: bool,
    /// `descr.type` is "sell" (parse_order_data downcases it); for a trade aggregate, its `type`.
    pub sell: bool,
}

pub struct Config {
    pub base_url: String,
    /// The proxy deltabadger configures for Kraken: `http://[user:pass@]host:port`.
    pub proxy: Option<String>,
    pub user_agent: String,
    pub timeouts: Timeouts,
    /// None: private calls go unsigned and Kraken refuses them, as Rails does with no saved key.
    pub credentials: Option<Credentials>,
    /// Tests and the parity scripts only: trust this store instead of the webpki roots.
    #[doc(hidden)]
    pub tls_roots: Option<Arc<rustls::RootCertStore>>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            base_url: DEFAULT_URL.into(),
            proxy: None,
            user_agent: DEFAULT_USER_AGENT.into(),
            timeouts: Timeouts::default(),
            credentials: None,
            tls_roots: None,
        }
    }
}

pub struct Client {
    transport: Transport,
    credentials: Option<Credentials>,
    user_agent: String,
}

fn one(s: &str) -> Param {
    Param::One(s.to_string())
}

fn rejected(errors: Vec<Value>) -> VenueError {
    VenueError::Rejected(
        errors
            .iter()
            .map(|v| semantics::to_s(v).unwrap_or_else(|_| v.to_string()))
            .collect(),
    )
}

/// Exchange::PLACEMENT_SAFE_TRANSIENT_ERRORS: provably pre-trade, so a definitive refusal.
const PLACEMENT_SAFE: [&str; 2] = [
    "Timestamp for this request is outside of the recvWindow",
    "Timestamp for this request was",
];
/// Client::NETWORK_TRANSIENT_PATTERNS, verbatim.
const NETWORK_TRANSIENT: [&str; 12] = [
    "Net::ReadTimeout",
    "Net::OpenTimeout",
    "Faraday::TimeoutError",
    "Faraday::ConnectionFailed",
    "execution expired",
    "Connection reset",
    "Errno::ECONNRESET",
    "connection refused",
    "Connection refused",
    "Errno::ECONNREFUSED",
    "end of file reached",
    "unexpected eof while reading",
];
/// Exchanges::Kraken::ERRORS[:transient], verbatim.
const KRAKEN_TRANSIENT: [&str; 5] = [
    "EGeneral:Internal error",
    "EAPI:Invalid nonce",
    "EService:Unavailable",
    "EService:Busy",
    "EService:Deadline elapsed",
];

/// `/\bHTTP 5\d\d\b/`.
fn http_5xx(m: &str) -> bool {
    let word = |c: u8| c.is_ascii_alphanumeric() || c == b'_';
    let b = m.as_bytes();
    m.match_indices("HTTP 5").any(|(i, _)| {
        (i == 0 || !word(b[i - 1]))
            && b.get(i + 6).is_some_and(u8::is_ascii_digit)
            && b.get(i + 7).is_some_and(u8::is_ascii_digit)
            && !b.get(i + 8).is_some_and(|&c| word(c))
    })
}

/// ActiveSupport's Array#to_sentence.
fn to_sentence(v: &[String]) -> String {
    match v {
        [] => String::new(),
        [a] => a.clone(),
        [a, b] => format!("{a} and {b}"),
        [init @ .., last] => format!("{}, and {last}", init.join(", ")),
    }
}

/// Exchange#ambiguous_placement_error?'s text rules for a refused AddOrder (Ruling R19): a refusal
/// Rails treats as "may have been placed" is Ambiguous, so the engine keeps the intent and
/// reconciles. Transport failures and statuses were already classified by `outcome`.
fn placement(e: VenueError) -> VenueError {
    let VenueError::Rejected(errors) = e else {
        return e;
    };
    let any = |patterns: &[&str]| {
        errors
            .iter()
            .any(|m| patterns.iter().any(|p| m.contains(p)))
    };
    if any(&PLACEMENT_SAFE) {
        return VenueError::Rejected(errors);
    }
    if any(&NETWORK_TRANSIENT) || any(&KRAKEN_TRANSIENT) || errors.iter().any(|m| http_5xx(m)) {
        return VenueError::Ambiguous(to_sentence(&errors));
    }
    VenueError::Rejected(errors)
}

/// A body the normalizer could not read: Rails treats a client_error as ambiguous (Ruling R8).
fn unreadable<E: std::fmt::Debug>(e: NormError<E>) -> VenueError {
    VenueError::Ambiguous(format!("{UNREADABLE} ({e:?})"))
}

fn finished<T>(f: Finished<T>) -> Result<T, VenueError> {
    match f {
        Finished::Ok(v) => Ok(v),
        Finished::Venue(e) => Err(rejected(e)),
        Finished::Unreadable => Err(VenueError::Ambiguous(UNREADABLE.into())),
    }
}

fn text(v: &Value) -> String {
    semantics::to_s(v).unwrap_or_else(|_| v.to_string())
}

fn state(o: NormalizedOrder<BigDecimal>) -> OrderState {
    OrderState {
        txid: text(&o.order_id),
        status: match o.status {
            CoreStatus::Open => OrderStatus::Open,
            CoreStatus::Closed => OrderStatus::Closed,
            CoreStatus::Cancelled => OrderStatus::Cancelled,
            CoreStatus::Failed | CoreStatus::Unknown => OrderStatus::Unknown,
        },
        price: o.price,
        amount: o.amount,
        quote_amount: o.quote_amount,
        amount_exec: o.amount_exec,
        quote_amount_exec: o.quote_amount_exec,
        limit: o.order_type == OrderType::Limit,
        sell: o
            .side
            .as_ref()
            .is_some_and(|s| semantics::string_eq(s, "sell")),
    }
}

/// What Exchanges::Kraken#set_market_order / #set_limit_order send, plus cl_ord_id and deadline.
fn order_params(o: &NewOrder, validate: bool) -> BTreeMap<String, Param> {
    let mut p = BTreeMap::from([
        (
            "ordertype".to_string(),
            one(match o.kind {
                OrderKind::Market => "market",
                OrderKind::Limit { .. } => "limit",
            }),
        ),
        ("type".to_string(), one("buy")),
        ("volume".to_string(), one(&o.volume)),
        ("pair".to_string(), one(&o.pair)),
        (
            "oflags".to_string(),
            Param::Many(if o.quote_volume {
                vec!["viqc".into()]
            } else {
                vec![]
            }),
        ),
        ("cl_ord_id".to_string(), one(&o.cl_ord_id)),
        // Ruling R11: RFC 3339, UTC, milliseconds, Z.
        (
            "deadline".to_string(),
            one(&o.deadline.to_rfc3339_opts(SecondsFormat::Millis, true)),
        ),
    ]);
    if let OrderKind::Limit { price } = &o.kind {
        p.insert("price".to_string(), one(price));
    }
    if validate {
        p.insert("validate".to_string(), one("true"));
    }
    p
}

impl Client {
    pub fn new(config: Config) -> Result<Self, ConfigError> {
        let transport = Transport::new(
            &config.base_url,
            config.proxy.as_deref(),
            config.timeouts,
            config.tls_roots,
        )?;
        Ok(Self {
            transport,
            credentials: config.credentials,
            user_agent: config.user_agent,
        })
    }

    /// One Kraken call: the core lays it out and signs it (nonce included); the transport sends it
    /// once, on its own connection.
    async fn call(&self, op: &str, params: BTreeMap<String, Param>) -> Result<Value, VenueError> {
        let built = requests::build(op, &params, self.credentials.as_ref())
            .expect("a layout exists for every op this client calls");
        let headers = built
            .headers
            .into_iter()
            .map(|(k, v)| {
                if k == "User-Agent" {
                    (k, self.user_agent.clone())
                } else {
                    (k, v)
                }
            })
            .collect();
        let req = match built.method {
            Method::Post => Request {
                method: "POST",
                path_and_query: built.path.to_string(),
                headers,
                body: built.body,
            },
            Method::Get => {
                let mut pairs = built.pairs;
                pairs.sort_by(|a, b| a.0.cmp(&b.0)); // Faraday's params encoder sorts (Ruling R17)
                let q = www_form(&pairs);
                let path_and_query = if q.is_empty() {
                    built.path.to_string()
                } else {
                    format!("{}?{q}", built.path)
                };
                Request {
                    method: "GET",
                    path_and_query,
                    headers,
                    body: None,
                }
            }
        };
        outcome(self.transport.request(&req).await)
    }

    pub async fn prices(&self, pair: &str) -> Result<Prices, VenueError> {
        let data = self
            .call(
                "get_ticker_information",
                BTreeMap::from([("pair".to_string(), one(pair))]),
            )
            .await?;
        match finished(normalize::ticker_prices::<BigDecimal>(&data).map_err(unreadable)?)? {
            Some(t) => Ok(Prices {
                bid: t.bid,
                ask: t.ask,
                last: t.last,
            }),
            None => Err(VenueError::Rejected(vec![format!(
                "Failed to get Kraken {pair} ticker information"
            )])),
        }
    }

    /// Sent at most once. Never retried. A refusal Rails would treat as possibly placed is Ambiguous.
    pub async fn add_order(&self, order: &NewOrder) -> Result<String, VenueError> {
        let data = self
            .call("add_order", order_params(order, false))
            .await
            .map_err(placement)?;
        match finished(normalize::add_order::<BigDecimal>(&data).map_err(unreadable)?)
            .map_err(placement)?
        {
            Value::String(txid) if !txid.is_empty() => Ok(txid),
            _ => Err(VenueError::Ambiguous(format!(
                "Failed to set Kraken {} order (order_id is nil)",
                match order.kind {
                    OrderKind::Market => "market",
                    OrderKind::Limit { .. } => "limit",
                }
            ))),
        }
    }

    /// AddOrder with validate=true: Kraken checks the signed order without placing it (live checks).
    /// Deliberately skips placement rules because `validate=true` never places an order.
    pub async fn add_order_validate(&self, order: &NewOrder) -> Result<(), VenueError> {
        let data = self.call("add_order", order_params(order, true)).await?;
        finished(normalize::add_order::<BigDecimal>(&data).map_err(unreadable)?).map(|_| ())
    }

    /// QueryOrders (the caller batches ≤ 50); ids Kraken does not report are absent.
    pub async fn orders(&self, txids: &[String]) -> Result<Vec<OrderState>, VenueError> {
        let params = BTreeMap::from([
            ("txid".to_string(), one(&txids.join(","))),
            ("consolidate_taker".to_string(), one("true")),
        ]);
        let data = self.call("query_orders_info", params).await?;
        Ok(
            finished(normalize::orders::<BigDecimal>(&data).map_err(unreadable)?)?
                .into_iter()
                .map(state)
                .collect(),
        )
    }

    /// OpenOrders, then every ClosedOrders page since `since`. `Ok(None)` only after a complete scan.
    pub async fn order_by_client_id(
        &self,
        cl_ord_id: &str,
        since: DateTime<Utc>,
    ) -> Result<Option<OrderState>, VenueError> {
        let mut lookup = ClientIdLookup::new(cl_ord_id, since.timestamp());
        let mut step = lookup.first::<BigDecimal>();
        loop {
            step = match step {
                Step::Call(op, params) => {
                    let data = self.call(op, params).await?;
                    lookup.feed::<BigDecimal>(&data).map_err(unreadable)?
                }
                Step::Found(o) => return Ok(Some(state(o))),
                Step::Absent => return Ok(None),
                Step::Venue(e) => return Err(rejected(e)),
                Step::Unreadable => return Err(VenueError::Ambiguous(UNREADABLE.into())),
                Step::Incomplete(m) => return Err(VenueError::Ambiguous(m)),
            };
        }
    }
}
