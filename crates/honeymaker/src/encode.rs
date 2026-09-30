//! The encoders the legacy Ruby used, byte for byte (tests/vectors).

/// URI.encode_www_form: keep A-Z a-z 0-9 * - . _, space → +, everything else %XX (uppercase).
pub fn www_form(pairs: &[(String, String)]) -> String {
    fn enc(s: &str) -> String {
        let mut o = String::with_capacity(s.len());
        for &b in s.as_bytes() {
            match b {
                b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'*' | b'-' | b'.' | b'_' => {
                    o.push(b as char)
                }
                b' ' => o.push('+'),
                _ => o.push_str(&format!("%{b:02X}")),
            }
        }
        o
    }
    pairs
        .iter()
        .map(|(k, v)| format!("{}={}", enc(k), enc(v)))
        .collect::<Vec<_>>()
        .join("&")
}

/// Base64.decode64 = String#unpack1("m"): a literal port of ruby/pack.c's lenient branch
/// (skips bytes outside the alphabet; '=' in the third/fourth slot ends the input).
pub fn ruby_decode64(input: &[u8]) -> Vec<u8> {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let table = |c: u8| -> i32 {
        T.iter()
            .position(|&x| x == c)
            .map(|p| p as i32)
            .unwrap_or(-1)
    };
    let n = input.len();
    let at = |i: usize| -> u8 { if i < n { input[i] } else { 0 } }; // C strings end in NUL
    let mut out = Vec::with_capacity(n * 3 / 4 + 3);
    let mut s = 0usize;
    let (mut a, mut b, mut c): (i32, i32, i32) = (-1, -1, 0);
    while s < n {
        b = -1;
        c = -1;
        loop {
            a = table(at(s));
            if !(a == -1 && s < n) {
                break;
            }
            s += 1;
        }
        if s >= n {
            break;
        }
        s += 1;
        loop {
            b = table(at(s));
            if !(b == -1 && s < n) {
                break;
            }
            s += 1;
        }
        if s >= n {
            break;
        }
        s += 1;
        loop {
            c = table(at(s));
            if !(c == -1 && s < n) {
                break;
            }
            if at(s) == b'=' {
                break;
            }
            s += 1;
        }
        if at(s) == b'=' || s >= n {
            break;
        }
        s += 1;
        let mut d;
        loop {
            d = table(at(s));
            if !(d == -1 && s < n) {
                break;
            }
            if at(s) == b'=' {
                break;
            }
            s += 1;
        }
        if at(s) == b'=' || s >= n {
            break;
        }
        s += 1;
        out.push(((a << 2) | (b >> 4)) as u8);
        out.push(((b << 4) | (c >> 2)) as u8);
        out.push(((c << 6) | d) as u8);
        a = -1;
    }
    if a != -1 && b != -1 {
        out.push(((a << 2) | (b >> 4)) as u8);
        if c != -1 {
            out.push(((b << 4) | (c >> 2)) as u8);
        }
    }
    out
}
