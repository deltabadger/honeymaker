use magnus::{function, prelude::*, Error, Ruby};

fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let native = ruby.define_module("Honeymaker")?.define_module("Native")?;
    let ext = native.define_module("Ext")?;
    ext.define_singleton_method("version", function!(version, 0))?;
    Ok(())
}
