use magnus::{Error, Ruby, function, prelude::*};

mod convert;
mod ruby_decimal;

fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

fn roundtrip_for_tests(ruby: &Ruby, v: magnus::Value) -> Result<magnus::Value, Error> {
    let j = convert::to_json(ruby, v)?;
    convert::from_json(ruby, &j)
}

fn decimal_for_tests(text: String) -> Result<magnus::Value, Error> {
    use honeymaker_core::num::Num;
    Ok(ruby_decimal::RubyDecimal::parse(&text)?.value())
}

fn to_s_for_tests(ruby: &Ruby, v: magnus::Value) -> Result<String, Error> {
    let j = convert::to_json(ruby, v)?;
    honeymaker_core::semantics::to_s(&j).map_err(|msg| convert::shape(ruby, &msg))
}

fn decimal_convert_for_tests(
    ruby: &Ruby,
    v: magnus::Value,
    stringify: bool,
) -> Result<magnus::Value, Error> {
    use honeymaker_core::num::Num;
    use ruby_decimal::RubyDecimal;
    let j = convert::to_json(ruby, v)?;
    let decimal = if stringify {
        RubyDecimal::parse_to_s(&j)?
    } else {
        RubyDecimal::parse_json(&j)?
    };
    Ok(decimal.value())
}

fn decimal_arithmetic_for_tests(
    ruby: &Ruby,
    left: String,
    right: String,
) -> Result<magnus::RArray, Error> {
    use honeymaker_core::num::Num;
    use magnus::value::BoxValue;
    use ruby_decimal::RubyDecimal;

    // Keep the decimals on the Rust heap across collection and compaction, as normalizers will.
    let mut decimals = vec![RubyDecimal::parse(&left)?, RubyDecimal::parse(&right)?];
    let sum = decimals[0].add(&decimals[1])?;
    decimals.push(sum);
    decimals.push(decimals[0].sub(&decimals[1])?);
    decimals.push(decimals[0].div(&decimals[1])?);
    ruby.gc_start();
    let gc = BoxValue::new(ruby.class_object().const_get::<_, magnus::RModule>("GC")?);
    if gc.respond_to("compact", false)? {
        gc.funcall::<_, _, magnus::Value>("compact", ())?;
    }
    let out = BoxValue::new(ruby.ary_new_capa(4));
    for decimal in &decimals[2..] {
        out.push(decimal.value())?;
    }
    out.push(decimals[0].is_zero()?)?;
    Ok(*out)
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    use magnus::value::BoxValue;
    ruby.require("bigdecimal")?;
    let native = BoxValue::new(ruby.define_module("Honeymaker")?.define_module("Native")?);
    let ext = BoxValue::new(native.define_module("Ext")?);
    ext.define_singleton_method("version", function!(version, 0))?;
    ext.define_singleton_method("roundtrip_for_tests", function!(roundtrip_for_tests, 1))?;
    ext.define_singleton_method("decimal_for_tests", function!(decimal_for_tests, 1))?;
    ext.define_singleton_method("to_s_for_tests", function!(to_s_for_tests, 1))?;
    ext.define_singleton_method(
        "decimal_convert_for_tests",
        function!(decimal_convert_for_tests, 2),
    )?;
    ext.define_singleton_method(
        "decimal_arithmetic_for_tests",
        function!(decimal_arithmetic_for_tests, 2),
    )?;
    Ok(())
}
