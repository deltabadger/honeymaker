//! Unified clients for cryptocurrency exchange APIs: request builders, signing, normalizers.
//! No Ruby and no I/O. The honeymaker gem wraps it; deltabadger-rs will use it directly.

pub mod encode;
pub mod kraken;
pub mod num;
pub mod semantics;
pub mod types;

pub use types::{Balance, Order, OrderId, OrderStatus, OrderType, Side};
