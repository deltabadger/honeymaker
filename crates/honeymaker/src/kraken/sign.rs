use crate::encode::ruby_decode64;
use base64::Engine;
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256, Sha512};
use std::collections::HashMap;
use std::sync::Mutex;

#[derive(Clone)]
pub struct Credentials {
    pub api_key: String,
    pub api_secret: String,
}

/// The secret never reaches a log or a panic message.
impl std::fmt::Debug for Credentials {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Credentials")
            .field("api_key", &self.api_key)
            .field("api_secret", &"<redacted>")
            .finish()
    }
}

impl Credentials {
    pub fn authenticated(&self) -> bool {
        !self.api_key.is_empty() && !self.api_secret.is_empty()
    }
}

// Kraken rejects a nonce <= the last it saw per API key: µs clock, max(now, last + 1), per key.
// Cross-process reuse of a key is not protected, as in the legacy gem. The binding calls this
// with the GVL held, so a fork never finds these mutexes locked.
static NONCES: Mutex<Option<HashMap<[u8; 32], u64>>> = Mutex::new(None);
static FIXED: Mutex<Option<u64>> = Mutex::new(None);

pub fn next_nonce(api_key: Option<&str>) -> u64 {
    if let Some(n) = *FIXED.lock().unwrap_or_else(|p| p.into_inner()) {
        return n;
    }
    let key: [u8; 32] = Sha256::digest(api_key.unwrap_or("\0__no_api_key__").as_bytes()).into();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_micros() as u64;
    let mut g = NONCES.lock().unwrap_or_else(|p| p.into_inner());
    let map = g.get_or_insert_with(HashMap::new);
    let next = now.max(map.get(&key).copied().unwrap_or(0) + 1);
    map.insert(key, next);
    next
}

/// Test hook: every nonce is `n` until reset to None.
pub fn set_fixed_nonce(n: Option<u64>) {
    *FIXED.lock().unwrap_or_else(|p| p.into_inner()) = n;
}

pub fn reset_nonces() {
    *NONCES.lock().unwrap_or_else(|p| p.into_inner()) = None;
}

pub fn public_headers() -> Vec<(String, String)> {
    vec![
        ("Accept".into(), "application/json".into()),
        ("Content-Type".into(), "application/json".into()),
        ("User-Agent".into(), "Honeymaker Ruby".into()),
    ]
}

/// Legacy: nonce taken back out of the body; message = path + SHA256(nonce + body);
/// key = Base64.decode64(secret); HMAC-SHA512; strict Base64.
pub fn private_headers(
    path: &str,
    body: &str,
    creds: Option<&Credentials>,
) -> Vec<(String, String)> {
    let Some(c) = creds.filter(|c| c.authenticated()) else {
        return public_headers();
    };
    let nonce = body
        .split('&')
        .find_map(|kv| kv.strip_prefix("nonce="))
        .unwrap_or("");
    let mut data = nonce.as_bytes().to_vec();
    data.extend_from_slice(body.as_bytes());
    let mut message = path.as_bytes().to_vec();
    message.extend_from_slice(&Sha256::digest(&data));
    let mut mac = Hmac::<Sha512>::new_from_slice(&ruby_decode64(c.api_secret.as_bytes()))
        .expect("HMAC takes any key length");
    mac.update(&message);
    let sign = base64::engine::general_purpose::STANDARD.encode(mac.finalize().into_bytes());
    vec![
        ("API-Key".into(), c.api_key.clone()),
        ("API-Sign".into(), sign),
        ("Accept".into(), "application/json".into()),
        (
            "Content-Type".into(),
            "application/x-www-form-urlencoded".into(),
        ),
        ("User-Agent".into(), "Honeymaker Ruby".into()),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    // FIXED affects every key, so all nonce tests hold this guard until both stores are reset.
    static TEST_LOCK: Mutex<()> = Mutex::new(());
    struct NonceState {
        _guard: std::sync::MutexGuard<'static, ()>,
    }
    impl NonceState {
        fn new() -> Self {
            let guard = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
            set_fixed_nonce(None);
            reset_nonces();
            Self { _guard: guard }
        }
    }
    impl Drop for NonceState {
        fn drop(&mut self) {
            set_fixed_nonce(None);
            reset_nonces();
        }
    }

    #[test]
    fn ten_thousand_nonces_are_strictly_increasing() {
        let _state = NonceState::new();
        let mut last = next_nonce(Some("monotonic"));
        for _ in 1..10_000 {
            let next = next_nonce(Some("monotonic"));
            assert!(next > last, "{next} <= {last}");
            last = next;
        }
    }

    #[test]
    fn keys_have_independent_nonce_sequences() {
        let _state = NonceState::new();
        let future = u64::MAX - 10_000;
        let key: [u8; 32] = Sha256::digest(b"key-a").into();
        NONCES
            .lock()
            .unwrap()
            .get_or_insert_with(HashMap::new)
            .insert(key, future);
        assert_eq!(next_nonce(Some("key-a")), future + 1);
        let b = next_nonce(Some("key-b"));
        assert!(b < future, "key-a must not advance key-b");
        assert_eq!(next_nonce(Some("key-a")), future + 2);
        assert!(next_nonce(Some("key-b")) > b);
    }

    #[test]
    fn fixed_nonce_is_returned_until_cleared() {
        let _state = NonceState::new();
        set_fixed_nonce(Some(42));
        for key in [Some("key-a"), Some("key-b"), None] {
            assert_eq!(next_nonce(key), 42);
            assert_eq!(next_nonce(key), 42);
        }
        set_fixed_nonce(None);
        assert!(next_nonce(Some("key-a")) > 42);
    }
}
