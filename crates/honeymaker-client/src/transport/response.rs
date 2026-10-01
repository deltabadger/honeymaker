//! What the gem's Net::HTTP + Faraday stack turns an HTTP answer into (Ruling R6).
use super::{BodyFraming, Cause, Failure, Raw, Reply};
use flate2::read::{GzDecoder, ZlibDecoder};
use serde::de::{self, Deserialize, Deserializer, MapAccess, SeqAccess, Visitor};
use std::collections::HashSet;
use std::fmt;
use std::io::Read;

/// Faraday::Response::Json#process_response_type?: the media type before `;`, unstripped and
/// case-sensitive, matched against /\bjson$/.
fn json_type(content_type: Option<&str>) -> bool {
    let t = content_type.unwrap_or("").split(';').next().unwrap_or("");
    t.strip_suffix("json").is_some_and(|head| {
        !head
            .chars()
            .last()
            .is_some_and(|c| c.is_ascii_alphanumeric() || c == '_')
    })
}

/// Ruby String#strip: ASCII whitespace and NUL.
fn blank(b: &[u8]) -> bool {
    b.iter()
        .all(|c| matches!(c, b' ' | b'\t' | b'\n' | 0x0b | 0x0c | b'\r' | 0))
}

/// Net::HTTPResponse#inflater: gzip, x-gzip and deflate (any case) are inflated unless a
/// Content-Range is present; Zlib::Inflate.new(32 + MAX_WBITS) auto-detects a zlib or gzip header,
/// so both are accepted for each. Recognized encodings are removed even on empty bodies.
/// A Zlib error escaping Faraday's adapter is a client_error, post-send.
pub fn decode(mut raw: Raw) -> Result<Raw, Failure> {
    let enc = raw.content_encoding.as_deref().map(str::to_ascii_lowercase);
    if raw.content_range {
        return Ok(raw);
    }
    match enc.as_deref() {
        Some("gzip" | "x-gzip" | "deflate") => raw.content_encoding = None,
        Some("none" | "identity") => {
            raw.content_encoding = None;
            return Ok(raw);
        }
        _ => return Ok(raw),
    }
    if raw.body.is_empty() {
        return Ok(raw);
    }
    let mut out = Vec::new();
    let result = if raw.body.starts_with(&[0x1f, 0x8b]) {
        GzDecoder::new(&raw.body[..]).read_to_end(&mut out)
    } else {
        ZlibDecoder::new(&raw.body[..]).read_to_end(&mut out)
    };
    if let Err(e) = result {
        if e.kind() != std::io::ErrorKind::UnexpectedEof {
            return Err(Failure::new(Cause::Other, format!("Zlib::DataError: {e}")));
        }
        // net-http 0.9.1 read_body_0 returns from inside the inflater block for length/chunked
        // bodies. Its ensure then suppresses finish's error because `success` was never set.
        if raw.framing == BodyFraming::CloseDelimited {
            return Err(Failure::new(Cause::Other, "Zlib::BufError: buffer error"));
        }
        // Ruby's block-form Inflate#inflate yields full 16 KiB buffers, flushing the remainder
        // only on stream end. An incomplete stream never delivers that pending remainder.
        const RUBY_ZLIB_BUFFER: usize = 16 * 1024;
        out.truncate(out.len() / RUBY_ZLIB_BUFFER * RUBY_ZLIB_BUFFER);
    }
    raw.body = out.into();
    Ok(raw)
}

pub fn shape(method: &str, url: &str, raw: Raw) -> Reply {
    let text = || String::from_utf8_lossy(&raw.body).into_owned();
    if (400..=599).contains(&raw.status) {
        let message = if raw.body.is_empty() {
            if raw.status == 407 {
                "407 \"Proxy Authentication Required\"".into()
            } else {
                format!(
                    "the server responded with status {} for {} {url}",
                    raw.status,
                    method.to_uppercase()
                )
            }
        } else {
            text()
        };
        return Reply::Status {
            status: raw.status,
            message,
        };
    }
    if !json_type(raw.content_type.as_deref()) || blank(&raw.body) {
        return Reply::NotJson;
    }
    match parse_strict(&raw.body) {
        Some(v) => Reply::Parsed(v),
        None => Reply::Status {
            status: raw.status,
            message: text(),
        },
    }
}

/// JSON.parse under json 3.0.2: duplicate keys and nesting above 100 are parse errors.
fn parse_strict(body: &[u8]) -> Option<serde_json::Value> {
    let v = serde_json::from_slice(body).ok()?;
    if !within_nesting_limit(&v, 0) {
        return None;
    }
    serde_json::from_slice::<NoDuplicateKeys>(body).ok()?;
    Some(v)
}

fn within_nesting_limit(value: &serde_json::Value, depth: usize) -> bool {
    // JSON 3.0.2 handles empty containers before incrementing current_nesting. Walking Value
    // also avoids counting arbitrary_precision's synthetic number maps as JSON containers.
    match value {
        serde_json::Value::Array(a) if !a.is_empty() => {
            depth < 100 && a.iter().all(|v| within_nesting_limit(v, depth + 1))
        }
        serde_json::Value::Object(m) if !m.is_empty() => {
            depth < 100 && m.values().all(|v| within_nesting_limit(v, depth + 1))
        }
        _ => true,
    }
}

/// Walks a document and fails on the first repeated key. With `arbitrary_precision`, numbers
/// arrive as one-key maps, which pass.
struct NoDuplicateKeys;
impl<'de> Deserialize<'de> for NoDuplicateKeys {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        d.deserialize_any(Walk)
    }
}
struct Walk;
impl<'de> Visitor<'de> for Walk {
    type Value = NoDuplicateKeys;
    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("JSON")
    }
    fn visit_bool<E>(self, _: bool) -> Result<Self::Value, E> {
        Ok(NoDuplicateKeys)
    }
    fn visit_i64<E>(self, _: i64) -> Result<Self::Value, E> {
        Ok(NoDuplicateKeys)
    }
    fn visit_u64<E>(self, _: u64) -> Result<Self::Value, E> {
        Ok(NoDuplicateKeys)
    }
    fn visit_f64<E>(self, _: f64) -> Result<Self::Value, E> {
        Ok(NoDuplicateKeys)
    }
    fn visit_str<E>(self, _: &str) -> Result<Self::Value, E> {
        Ok(NoDuplicateKeys)
    }
    fn visit_unit<E>(self) -> Result<Self::Value, E> {
        Ok(NoDuplicateKeys)
    }
    fn visit_seq<A: SeqAccess<'de>>(self, mut a: A) -> Result<Self::Value, A::Error> {
        while a.next_element::<NoDuplicateKeys>()?.is_some() {}
        Ok(NoDuplicateKeys)
    }
    fn visit_map<A: MapAccess<'de>>(self, mut m: A) -> Result<Self::Value, A::Error> {
        let mut seen = HashSet::new();
        while let Some(k) = m.next_key::<String>()? {
            if !seen.insert(k.clone()) {
                return Err(de::Error::custom(format!("duplicate key {k:?}")));
            }
            m.next_value::<NoDuplicateKeys>()?;
        }
        Ok(NoDuplicateKeys)
    }
}
