//! What the gem's Net::HTTP + Faraday stack turns an HTTP answer into (Ruling R6).
use super::{BodyFraming, Cause, Failure, Raw, Reply};
use flate2::read::{GzDecoder, ZlibDecoder};
use serde::de::{Deserialize, Deserializer, Visitor};
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

/// JSON 3.0.2 accepts invalid UTF-8 in strings. Rust values use replacement characters;
/// downstream interpretation uses ASCII tokens. Syntax (including escapes and surrogates)
/// remains strict, and duplicate keys are compared as unescaped bytes before lossy conversion.
fn parse_strict(body: &[u8]) -> Option<serde_json::Value> {
    let text = String::from_utf8_lossy(body);
    let value = serde_json::from_str(&text).ok()?;
    validate_structure(body)?;
    Some(value)
}

/// The lossy parse has already checked grammar. Walk the original tokens to check byte-key
/// identity and depth: distinct invalid keys can collapse in Value, hiding keys or subtrees.
fn validate_structure(mut body: &[u8]) -> Option<()> {
    let mut containers: Vec<Option<HashSet<Vec<u8>>>> = Vec::new();
    while let Some((&token, rest)) = body.split_first() {
        match token {
            b'{' | b'[' => {
                containers.push((token == b'{').then(HashSet::new));
                // json 3.0.2 handles empty containers before incrementing current_nesting.
                let closing = if token == b'{' { b'}' } else { b']' };
                if containers.len() > 100
                    && rest.iter().find(|b| !b.is_ascii_whitespace()) != Some(&closing)
                {
                    return None;
                }
            }
            b'}' | b']' => {
                containers.pop()?;
            }
            b'"' => {
                let mut strings =
                    serde_json::Deserializer::from_slice(body).into_iter::<ByteString>();
                let string = strings.next()?.ok()?.0;
                body = &body[strings.byte_offset()..];
                if body.iter().find(|b| !b.is_ascii_whitespace()) == Some(&b':')
                    && !containers.last_mut()?.as_mut()?.insert(string)
                {
                    return None;
                }
                continue;
            }
            _ => {}
        }
        body = rest;
    }
    Some(())
}

/// serde's byte-string decoder retains invalid UTF-8 and unescapes keys for comparison.
/// Its permissive escape handling is safe only after the strict string parse above.
struct ByteString(Vec<u8>);
impl<'de> Deserialize<'de> for ByteString {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        d.deserialize_bytes(ByteStringVisitor)
    }
}
struct ByteStringVisitor;
impl<'de> Visitor<'de> for ByteStringVisitor {
    type Value = ByteString;
    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("a JSON string")
    }
    fn visit_bytes<E>(self, bytes: &[u8]) -> Result<Self::Value, E> {
        Ok(ByteString(bytes.to_vec()))
    }
}
