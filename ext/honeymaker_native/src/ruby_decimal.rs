use honeymaker_core::num::Num;
use magnus::{Ruby, Value, prelude::*, value::BoxValue};

/// Ruby's BigDecimal behind the core's Num trait. BoxValue registers the object with the GC,
/// so it is safe inside the Vecs and structs the normalizers return. Calls retain the GVL.
pub struct RubyDecimal(BoxValue<Value>);

impl RubyDecimal {
    pub fn value(&self) -> Value {
        *self.0
    }

    fn wrap(v: Value) -> Self {
        RubyDecimal(BoxValue::new(v))
    }

    fn ruby() -> Ruby {
        Ruby::get().expect("called on a Ruby thread")
    }
}

impl Num for RubyDecimal {
    type Error = magnus::Error;

    fn parse(text: &str) -> Result<Self, magnus::Error> {
        Ok(Self::wrap(
            Self::ruby()
                .module_kernel()
                .funcall("BigDecimal", (text,))?,
        ))
    }

    fn parse_to_s(v: &serde_json::Value) -> Result<Self, magnus::Error> {
        let ruby = Self::ruby();
        let obj = BoxValue::new(crate::convert::from_json(&ruby, v)?);
        let text = BoxValue::new(obj.funcall::<_, _, Value>("to_s", ())?);
        Ok(Self::wrap(
            ruby.module_kernel().funcall("BigDecimal", (*text,))?,
        ))
    }

    fn parse_json(v: &serde_json::Value) -> Result<Self, magnus::Error> {
        let ruby = Self::ruby();
        let obj = BoxValue::new(crate::convert::from_json(&ruby, v)?);
        Ok(Self::wrap(
            ruby.module_kernel().funcall("BigDecimal", (*obj,))?,
        ))
    }

    fn string_op(
        v: &serde_json::Value,
        op: honeymaker_core::semantics::StringOp<'_>,
    ) -> Result<serde_json::Value, magnus::Error> {
        use honeymaker_core::semantics::StringOp;
        let ruby = Self::ruby();
        let obj = BoxValue::new(crate::convert::from_json(&ruby, v)?);
        let result: Value = match op {
            StringOp::Index(key) => obj.funcall("[]", (key,))?,
            StringOp::Split(sep) => obj.funcall("split", (sep,))?,
            StringOp::First => obj.funcall("[]", (0,))?,
            StringOp::DowncaseSymbol | StringOp::Symbol => {
                let text = BoxValue::new(if matches!(op, StringOp::DowncaseSymbol) {
                    obj.funcall("downcase", ())?
                } else {
                    *obj
                });
                // Validate now, in legacy's evaluation order, before parsing decimals.
                text.funcall::<_, _, Value>("to_sym", ())?;
                *text
            }
        };
        crate::convert::to_json(&ruby, result)
    }

    fn add(&self, o: &Self) -> Result<Self, magnus::Error> {
        Ok(Self::wrap(self.value().funcall("+", (o.value(),))?))
    }

    fn sub(&self, o: &Self) -> Result<Self, magnus::Error> {
        Ok(Self::wrap(self.value().funcall("-", (o.value(),))?))
    }

    fn div(&self, o: &Self) -> Result<Self, magnus::Error> {
        Ok(Self::wrap(self.value().funcall("/", (o.value(),))?))
    }

    fn is_zero(&self) -> Result<bool, magnus::Error> {
        self.value().funcall("zero?", ())
    }
}
