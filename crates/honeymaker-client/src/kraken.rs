//! Kraken for Rust callers: the calls deltabadger's engine makes, with its `Venue` trait's
//! signatures and error classes. Requests, signing, nonces and normalizers are the core's.
use crate::transport::{Failure, Reply};
use serde_json::Value;

pub const UNREADABLE: &str = "Kraken: unreadable response";

#[derive(Clone, Debug, PartialEq)]
pub enum VenueError {
    /// Kraken answered and refused: its `error` array verbatim, or an HTTP answer Rails treats as
    /// definitive (e.g. 4xx). Classifying the strings (throttle, transient…) is the caller's job.
    Rejected(Vec<String>),
    /// The request may have reached Kraken.
    Ambiguous(String),
    /// Nothing reached Kraken.
    Transient(String),
}

/// Exchange#ambiguous_placement_error? without its text rules (those stay with the caller, over
/// `Rejected` strings): a transport failure is decided by its cause alone; an HTTP answer by its
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
