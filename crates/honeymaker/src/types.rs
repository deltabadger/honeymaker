#[derive(Debug, Clone, PartialEq)]
pub struct Balance<D> {
    pub free: D,
    pub locked: D,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OrderStatus {
    Open,
    Closed,
    Cancelled,
    Failed,
    Unknown,
}

impl OrderStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            OrderStatus::Open => "open",
            OrderStatus::Closed => "closed",
            OrderStatus::Cancelled => "cancelled",
            OrderStatus::Failed => "failed",
            OrderStatus::Unknown => "unknown",
        }
    }
}

/// Legacy symbolizes whatever the venue sent, so a side that is neither buy nor sell survives.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Side {
    Buy,
    Sell,
    Other(String),
}

impl Side {
    pub fn from_venue(s: &str) -> Side {
        match s {
            "buy" => Side::Buy,
            "sell" => Side::Sell,
            other => Side::Other(other.to_string()),
        }
    }
    pub fn as_str(&self) -> &str {
        match self {
            Side::Buy => "buy",
            Side::Sell => "sell",
            Side::Other(s) => s,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OrderType {
    Market,
    Limit,
    Unknown,
}

impl OrderType {
    pub fn as_str(self) -> &'static str {
        match self {
            OrderType::Market => "market",
            OrderType::Limit => "limit",
            OrderType::Unknown => "unknown",
        }
    }
}

/// Opaque, venue-formatted order id, stable for storage.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct OrderId(pub String);

#[derive(Debug, Clone, PartialEq)]
pub struct Order<D> {
    pub id: OrderId,
    pub status: OrderStatus,
    pub side: Option<Side>,
    pub order_type: OrderType,
    pub price: Option<D>,
    pub amount: Option<D>,
    pub quote_amount: Option<D>,
    pub amount_exec: D,
    pub quote_amount_exec: D,
}
