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

/// Lossless Ruby String: [bytes, Encoding#name]. Never interpret this object as a Hash.
pub const RUBY_STRING: &str = "\u{0}ruby_string";

pub fn is_string(v: &Value) -> bool {
    v.is_string()
        || v.as_object()
            .is_some_and(|m| m.len() == 1 && m.contains_key(RUBY_STRING))
}

/// String operations whose encoding semantics belong to the embedding runtime.
pub enum StringOp<'a> {
    Index(&'a str),
    Split(&'a str),
    DowncaseSymbol,
    Symbol,
    First,
}

pub fn string_op(v: &Value, op: StringOp<'_>) -> Result<Value, String> {
    let s = v.as_str().ok_or("expected a UTF-8 string")?;
    Ok(match op {
        StringOp::Index(key) => {
            if s.contains(key) {
                Value::from(key)
            } else {
                Value::Null
            }
        }
        StringOp::Split(sep) => {
            let mut parts: Vec<Value> = s.split(sep).map(Value::from).collect();
            while parts.last().is_some_and(|v| v.as_str() == Some("")) {
                parts.pop();
            }
            Value::Array(parts)
        }
        StringOp::DowncaseSymbol => {
            Value::from(s.chars().flat_map(char::to_lowercase).collect::<String>())
        }
        StringOp::Symbol => v.clone(),
        StringOp::First => s
            .chars()
            .next()
            .map(|c| Value::from(c.to_string()))
            .unwrap_or(Value::Null),
    })
}

/// Equality to an ASCII venue token, including ASCII-compatible binary strings.
pub fn string_eq(v: &Value, token: &str) -> bool {
    if let Some(s) = v.as_str() {
        return s == token;
    }
    v.get(RUBY_STRING)
        .and_then(Value::as_array)
        .is_some_and(|parts| {
            parts[0].as_array().is_some_and(|bytes| {
                bytes.len() == token.len()
                    && bytes
                        .iter()
                        .zip(token.bytes())
                        .all(|(v, b)| v.as_u64() == Some(b as u64))
            })
        })
}

/// Escape keys that serde_json cannot represent directly, including literal escape prefixes.
pub const RUBY_KEY: &str = "\u{0}ruby_key:";
pub fn object_key(key: &str) -> Value {
    key.strip_prefix(RUBY_KEY)
        .and_then(|s| serde_json::from_str(s).ok())
        .unwrap_or_else(|| Value::from(key))
}
