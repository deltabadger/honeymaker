//! Ruby ⇄ JSON values. Root Ruby objects across calls with BoxValue; only Rust-owned JSON
//! values go in Rust collections. Ruby containers are filled as each element is created.

use magnus::{
    Float, Integer, RArray, RHash, RString, Ruby, Value,
    r_hash::ForEach,
    value::{BoxValue, ReprValue},
};

pub fn to_json(ruby: &Ruby, v: Value) -> Result<serde_json::Value, magnus::Error> {
    use serde_json::Value as J;
    let v = BoxValue::new(v);
    if v.is_nil() {
        return Ok(J::Null);
    }
    if v.is_kind_of(ruby.class_true_class()) {
        return Ok(J::Bool(true));
    }
    if v.is_kind_of(ruby.class_false_class()) {
        return Ok(J::Bool(false));
    }
    if let Some(s) = RString::from_value(*v) {
        return Ok(J::String(s.to_string()?));
    }
    if Integer::from_value(*v).is_some() || Float::from_value(*v).is_some() {
        // Preserve Float#to_s exactly: legacy passes these digits to BigDecimal.
        // Non-finite floats use the sentinel understood by semantics::to_s.
        let text: String = v.funcall("to_s", ())?;
        return Ok(match text.parse::<serde_json::Number>() {
            Ok(n) => J::Number(n),
            Err(_) => J::Object(serde_json::Map::from_iter([(
                honeymaker_core::semantics::RUBY_FLOAT.to_string(),
                J::String(text),
            )])),
        });
    }
    if let Some(a) = RArray::from_value(*v) {
        let a = BoxValue::new(a);
        let mut out = Vec::with_capacity(a.len());
        for i in 0..a.len() {
            out.push(to_json(ruby, a.entry(i as isize)?)?);
        }
        return Ok(J::Array(out));
    }
    if let Some(h) = RHash::from_value(*v) {
        let h = BoxValue::new(h);
        let mut m = serde_json::Map::new();
        h.foreach(|k: Value, val: Value| {
            let k = BoxValue::new(k);
            let val = BoxValue::new(val);
            let key = RString::from_value(*k)
                .ok_or_else(|| shape(ruby, "non-string key"))?
                .to_string()?;
            m.insert(key, to_json(ruby, *val)?);
            Ok(ForEach::Continue)
        })?;
        return Ok(J::Object(m));
    }
    Err(shape(ruby, &format!("unsupported value {}", v.inspect())))
}

pub fn from_json(ruby: &Ruby, v: &serde_json::Value) -> Result<Value, magnus::Error> {
    use serde_json::Value as J;
    Ok(match v {
        J::Null => ruby.qnil().as_value(),
        J::Bool(true) => ruby.qtrue().as_value(),
        J::Bool(false) => ruby.qfalse().as_value(),
        J::String(s) => ruby.str_new(s).as_value(),
        J::Number(n) => {
            let text = n.to_string();
            let conv = if text.contains(['.', 'e', 'E']) {
                "Float"
            } else {
                "Integer"
            };
            ruby.module_kernel().funcall(conv, (text,))?
        }
        J::Array(a) => {
            let out = BoxValue::new(ruby.ary_new_capa(a.len()));
            for e in a {
                out.push(from_json(ruby, e)?)?;
            }
            out.as_value()
        }
        J::Object(m) => {
            if let Some(J::String(text)) = m
                .get(honeymaker_core::semantics::RUBY_FLOAT)
                .filter(|_| m.len() == 1)
            {
                let f = match text.as_str() {
                    "Infinity" => f64::INFINITY,
                    "-Infinity" => f64::NEG_INFINITY,
                    _ => f64::NAN,
                };
                // Kernel#Float("Infinity") raises, so build the float directly.
                return Ok(ruby.float_from_f64(f).as_value());
            }
            let h = BoxValue::new(ruby.hash_new());
            for (k, val) in m {
                let key = BoxValue::new(ruby.str_new(k));
                let value = from_json(ruby, val)?;
                h.aset(*key, value)?;
            }
            h.as_value()
        }
    })
}

// Used by the normalizers added in subsequent tasks.
#[allow(dead_code)]
pub fn sym(s: &str) -> Value {
    Ruby::get()
        .expect("called on a Ruby thread")
        .sym_new(s)
        .as_value()
}

pub fn shape(ruby: &Ruby, msg: &str) -> magnus::Error {
    let class = ruby
        .eval::<magnus::ExceptionClass>("Honeymaker::Native::ShapeError")
        .unwrap_or_else(|_| ruby.exception_standard_error());
    magnus::Error::new(class, msg.to_string())
}
