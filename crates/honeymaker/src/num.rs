//! Decimal arithmetic the venue normalizers need. The Ruby binding supplies Ruby's own
//! BigDecimal (exact legacy semantics: NaN, signed zero, division precision, ArgumentError); Rust
//! callers use the bigdecimal crate.

use bigdecimal::BigDecimal;
use std::str::FromStr;

pub trait Num: Sized {
    type Error;
    /// Legacy `BigDecimal(text)`.
    fn parse(text: &str) -> Result<Self, Self::Error>;
    /// Legacy `BigDecimal(value.to_s)`: the Ruby impl stringifies with Ruby's own `to_s`, so
    /// arrays, hashes and non-finite Floats give Ruby's exact text and ArgumentError.
    fn parse_to_s(v: &serde_json::Value) -> Result<Self, Self::Error>;
    /// Legacy `BigDecimal(value)` on the parsed JSON object itself (no `to_s`): Integers and
    /// Strings convert, a Float raises ("can't omit precision for a Float."), others raise.
    fn parse_json(v: &serde_json::Value) -> Result<Self, Self::Error>;
    fn string_op(
        v: &serde_json::Value,
        op: crate::semantics::StringOp<'_>,
    ) -> Result<serde_json::Value, Self::Error>;
    fn add(&self, other: &Self) -> Result<Self, Self::Error>;
    fn sub(&self, other: &Self) -> Result<Self, Self::Error>;
    fn div(&self, other: &Self) -> Result<Self, Self::Error>;
    fn is_zero(&self) -> Result<bool, Self::Error>;
}

#[derive(Debug)]
pub enum NormError<E> {
    /// The payload doesn't have the documented shape.
    Shape(String),
    /// The decimal backend refused a value (Ruby impl: Ruby's own ArgumentError).
    Num(E),
}

impl<E> From<String> for NormError<E> {
    fn from(s: String) -> Self {
        NormError::Shape(s)
    }
}

impl<E> From<&str> for NormError<E> {
    fn from(s: &str) -> Self {
        NormError::Shape(s.to_string())
    }
}

/// For Rust callers: finite decimals with Ruby's string grammar (spaces around, `_` between
/// digits, d/D exponent). Non-finite values are errors here.
impl Num for BigDecimal {
    type Error = String;

    fn parse(text: &str) -> Result<Self, String> {
        let t = text.trim_matches(|c: char| c == ' ' || ('\t'..='\r').contains(&c));
        static RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
        let re = RE.get_or_init(|| {
            regex::Regex::new(
                r"^[+-]?(?:\d+(?:_\d+)*)?(?:\.(?:\d+(?:_\d+)*)?)?(?:[eEdD][+-]?\d+)?$",
            )
            .unwrap()
        });
        if !re.is_match(t) || !t.bytes().any(|b| b.is_ascii_digit()) {
            return Err(format!("invalid value for BigDecimal(): {text:?}"));
        }
        let mut s: String = t
            .chars()
            .filter(|&c| c != '_')
            .map(|c| if c == 'd' || c == 'D' { 'e' } else { c })
            .collect();
        for (from, to) in [("-.", "-0."), ("+.", "+0."), (".e", ".0e"), (".E", ".0E")] {
            s = s.replace(from, to);
        }
        if s.starts_with('.') {
            s.insert(0, '0');
        }
        if s.ends_with('.') {
            s.push('0');
        }
        BigDecimal::from_str(&s).map_err(|e| e.to_string())
    }
    fn parse_to_s(v: &serde_json::Value) -> Result<Self, String> {
        Self::parse(&crate::semantics::to_s(v)?)
    }
    fn parse_json(v: &serde_json::Value) -> Result<Self, String> {
        match v {
            serde_json::Value::String(s) => Self::parse(s),
            serde_json::Value::Number(n) if !n.to_string().contains(['.', 'e', 'E']) => {
                Self::parse(&n.to_string())
            }
            serde_json::Value::Number(_) => Err("can't omit precision for a Float.".into()),
            other => Err(format!("can't convert {other} into BigDecimal")),
        }
    }
    fn string_op(
        v: &serde_json::Value,
        op: crate::semantics::StringOp<'_>,
    ) -> Result<serde_json::Value, String> {
        crate::semantics::string_op(v, op)
    }
    fn add(&self, o: &Self) -> Result<Self, String> {
        Ok(self + o)
    }
    fn sub(&self, o: &Self) -> Result<Self, String> {
        Ok(self - o)
    }
    fn div(&self, o: &Self) -> Result<Self, String> {
        if o == &BigDecimal::from(0) {
            return Err("divided by 0".into());
        }
        Ok((self / o).with_prec(34))
    }
    fn is_zero(&self) -> Result<bool, String> {
        Ok(self == &BigDecimal::from(0))
    }
}
