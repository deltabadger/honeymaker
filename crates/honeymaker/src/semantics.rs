//! The Ruby semantics venue code relies on, made explicit.

use serde_json::Value;

/// Key of the one-entry object the binding uses for a non-finite Ruby Float ("Infinity", "NaN").
pub const RUBY_FLOAT: &str = "\u{0}ruby_float";

/// Legacy `x.to_s` for a JSON value: String as is, numbers as their digits (the binding gives
/// Ruby Floats their Float#to_s digits), nil → "", booleans → "true"/"false".
pub fn to_s(v: &Value) -> Result<String, String> {
    match v {
        Value::String(s) => Ok(s.clone()),
        Value::Number(n) => Ok(n.to_string()),
        Value::Null => Ok(String::new()),
        Value::Bool(b) => Ok(b.to_string()),
        Value::Object(m) if m.len() == 1 => match m.get(RUBY_FLOAT) {
            Some(Value::String(t)) => Ok(t.clone()),
            _ => Err(format!("no to_s for {v}")),
        },
        other => Err(format!("no to_s for {other}")),
    }
}

/// Ruby truthiness: everything except nil and false.
pub fn truthy(v: Option<&Value>) -> bool {
    !matches!(v, None | Some(Value::Null) | Some(Value::Bool(false)))
}

/// `s.split(sep).first`: Ruby drops trailing empty fields, so "" and "..." give nil.
pub fn split_first(s: &str, sep: char) -> Option<&str> {
    if s.split(sep).all(str::is_empty) {
        None
    } else {
        s.split(sep).next()
    }
}

/// `x.to_i` for JSON values: Integer as is, Float truncated, String's leading integer, else 0.
pub fn to_i(v: &Value) -> i64 {
    match v {
        Value::Number(n) => n
            .as_i64()
            .or_else(|| n.as_f64().map(|f| f.trunc() as i64))
            .unwrap_or(0),
        Value::String(s) => {
            let t = s.trim_start();
            let (sign, digits) = match t.strip_prefix('-') {
                Some(r) => (-1, r),
                None => (1, t.strip_prefix('+').unwrap_or(t)),
            };
            sign * digits
                .chars()
                .take_while(char::is_ascii_digit)
                .collect::<String>()
                .parse::<i64>()
                .unwrap_or(0)
        }
        _ => 0,
    }
}
