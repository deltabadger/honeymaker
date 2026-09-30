use crate::convert::{self, sym};
use crate::ruby_decimal::RubyDecimal;
use honeymaker_core::kraken::normalize::{self, Finished};
use honeymaker_core::kraken::requests::{Fields, Method, layout};
use honeymaker_core::kraken::sign::{self, Credentials};
use honeymaker_core::kraken::trades::aggregate;
use honeymaker_core::num::NormError;
use magnus::{RArray, RHash, Ruby, Value, prelude::*, r_hash::ForEach};

#[magnus::wrap(class = "Honeymaker::Native::Ext::Kraken", free_immediately)]
pub struct Kraken {
    creds: Option<Credentials>,
    /// Legacy keys the nonce store by the raw api_key; nil gets its own slot.
    nonce_key: Option<String>,
}

pub(crate) fn norm(ruby: &Ruby, e: NormError<magnus::Error>) -> magnus::Error {
    match e {
        NormError::Num(err) => err, // Ruby's own ArgumentError from BigDecimal()
        NormError::Shape(msg) => convert::shape(ruby, &msg),
    }
}

fn headers(ruby: &Ruby, pairs: &[(String, String)]) -> Result<RHash, magnus::Error> {
    let h = ruby.hash_new();
    for (k, v) in pairs {
        h.aset(k.as_str(), v.as_str())?;
    }
    Ok(h)
}

pub(crate) fn verdict<T>(
    ruby: &Ruby,
    f: Finished<T>,
    ok: impl FnOnce(T) -> Result<Value, magnus::Error>,
) -> Result<RArray, magnus::Error> {
    let out = ruby.ary_new();
    match f {
        Finished::Ok(v) => {
            out.push(ruby.str_new("ok"))?;
            out.push(ok(v)?)?;
        }
        Finished::Venue => out.push(ruby.str_new("venue"))?,
        Finished::Unreadable => out.push(ruby.str_new("unreadable"))?,
    }
    Ok(out)
}

fn opt_dec(ruby: &Ruby, d: &Option<RubyDecimal>) -> Value {
    d.as_ref()
        .map(|d| d.value())
        .unwrap_or_else(|| ruby.qnil().as_value())
}

impl Kraken {
    fn new(api_key: Option<String>, api_secret: Option<String>) -> Self {
        let creds = match (&api_key, &api_secret) {
            (None, None) => None,
            (k, s) => Some(Credentials {
                api_key: k.clone().unwrap_or_default(),
                api_secret: s.clone().unwrap_or_default(),
            }),
        };
        Kraken {
            creds,
            nonce_key: api_key,
        }
    }

    fn layout_for(
        ruby: &Ruby,
        op: &str,
        want: Method,
    ) -> Result<(&'static str, Fields), magnus::Error> {
        match layout(op) {
            Some((m, path, fields)) if m == want => Ok((path, fields)),
            _ => Err(convert::shape(
                ruby,
                &format!("unknown Kraken {want:?} op {op}"),
            )),
        }
    }

    /// → [path, [["nonce", Integer], [wire, original value], ...]] (nils dropped, legacy order)
    fn build_post(
        ruby: &Ruby,
        rb_self: &Self,
        op: String,
        params: RHash,
    ) -> Result<RArray, magnus::Error> {
        let (path, fields) = Self::layout_for(ruby, &op, Method::Post)?;
        let pairs = ruby.ary_new();
        let nonce = ruby.ary_new();
        nonce.push(ruby.str_new("nonce"))?;
        nonce.push(ruby.integer_from_u64(sign::next_nonce(rb_self.nonce_key.as_deref())))?;
        pairs.push(nonce)?;
        for (wire, name) in fields {
            let v: Value = params.aref(ruby.str_new(name))?;
            if !v.is_nil() {
                let pair = ruby.ary_new();
                pair.push(ruby.str_new(wire))?;
                pair.push(v)?;
                pairs.push(pair)?;
            }
        }
        let out = ruby.ary_new();
        out.push(ruby.str_new(path))?;
        out.push(pairs)?;
        Ok(out)
    }

    /// Signs the exact body Ruby encoded: legacy private_headers(req.path, req.body).
    fn sign(
        ruby: &Ruby,
        rb_self: &Self,
        path: String,
        body: String,
    ) -> Result<RHash, magnus::Error> {
        headers(
            ruby,
            &sign::private_headers(&path, &body, rb_self.creds.as_ref()),
        )
    }

    /// → [path, {wire => original value} (nils dropped), public headers]
    fn build_get(
        ruby: &Ruby,
        _rb_self: &Self,
        op: String,
        params: RHash,
    ) -> Result<RArray, magnus::Error> {
        let (path, fields) = Self::layout_for(ruby, &op, Method::Get)?;
        let query = ruby.hash_new();
        for (wire, name) in fields {
            let v: Value = params.aref(ruby.str_new(name))?;
            if !v.is_nil() {
                query.aset(ruby.str_new(wire), v)?;
            }
        }
        let out = ruby.ary_new();
        out.push(ruby.str_new(path))?;
        out.push(query)?;
        out.push(headers(ruby, &sign::public_headers())?)?;
        Ok(out)
    }

    fn finish(
        ruby: &Ruby,
        _rb_self: &Self,
        op: String,
        data: Value,
    ) -> Result<RArray, magnus::Error> {
        let json = convert::to_json(ruby, data)?;
        match op.as_str() {
            "balances" => verdict(
                ruby,
                normalize::balances::<RubyDecimal>(&json).map_err(|e| norm(ruby, e))?,
                |list| {
                    let h = ruby.hash_new();
                    for b in list {
                        let e = ruby.hash_new();
                        e.aset(sym("free"), b.free.value())?;
                        e.aset(sym("locked"), b.locked.value())?;
                        match b.asset {
                            Some(a) => h.aset(ruby.str_new(&a), e)?,
                            None => h.aset(ruby.qnil(), e)?,
                        }
                    }
                    Ok(h.as_value())
                },
            ),
            "query_orders_info" => verdict(
                ruby,
                normalize::orders::<RubyDecimal>(&json).map_err(|e| norm(ruby, e))?,
                |list| {
                    let h = ruby.hash_new();
                    for o in list {
                        let e = ruby.hash_new();
                        e.aset(sym("order_id"), convert::from_json(ruby, &o.order_id)?)?;
                        e.aset(sym("status"), sym(o.status.as_str()))?;
                        e.aset(
                            sym("side"),
                            o.side
                                .as_ref()
                                .map(|s| sym(s.as_str()))
                                .unwrap_or_else(|| ruby.qnil().as_value()),
                        )?;
                        e.aset(sym("order_type"), sym(o.order_type.as_str()))?;
                        e.aset(sym("price"), opt_dec(ruby, &o.price))?;
                        e.aset(sym("amount"), opt_dec(ruby, &o.amount))?;
                        e.aset(sym("quote_amount"), opt_dec(ruby, &o.quote_amount))?;
                        e.aset(sym("amount_exec"), o.amount_exec.value())?;
                        e.aset(sym("quote_amount_exec"), o.quote_amount_exec.value())?;
                        h.aset(convert::from_json(ruby, &o.order_id)?, e)?; // the wrapper appends :raw last
                    }
                    Ok(h.as_value())
                },
            ),
            "add_order" => verdict(
                ruby,
                normalize::add_order::<RubyDecimal>(&json).map_err(|e| norm(ruby, e))?,
                |id| convert::from_json(ruby, &id),
            ),
            "tickers_info" => verdict(
                ruby,
                normalize::tickers(&json).map_err(|m| convert::shape(ruby, &m))?,
                |list| {
                    let out = ruby.ary_new();
                    for t in list {
                        let h = ruby.hash_new();
                        let opt_str = |s: &Option<String>| {
                            s.as_deref()
                                .map(|x| ruby.str_new(x).as_value())
                                .unwrap_or_else(|| ruby.qnil().as_value())
                        };
                        h.aset(sym("ticker"), convert::from_json(ruby, &t.ticker)?)?;
                        h.aset(sym("base"), opt_str(&t.base))?;
                        h.aset(sym("quote"), opt_str(&t.quote))?;
                        h.aset(
                            sym("minimum_base_size"),
                            convert::from_json(ruby, &t.minimum_base_size)?,
                        )?;
                        h.aset(
                            sym("minimum_quote_size"),
                            convert::from_json(ruby, &t.minimum_quote_size)?,
                        )?;
                        h.aset(sym("maximum_base_size"), ruby.qnil())?;
                        h.aset(sym("maximum_quote_size"), ruby.qnil())?;
                        h.aset(
                            sym("base_decimals"),
                            convert::from_json(ruby, &t.base_decimals)?,
                        )?;
                        h.aset(
                            sym("quote_decimals"),
                            convert::from_json(ruby, &t.quote_decimals)?,
                        )?;
                        h.aset(
                            sym("price_decimals"),
                            convert::from_json(ruby, &t.price_decimals)?,
                        )?;
                        h.aset(sym("available"), ruby.qtrue())?;
                        h.aset(sym("trading_enabled"), t.trading_enabled)?;
                        out.push(h)?;
                    }
                    Ok(out.as_value())
                },
            ),
            "bid_ask" => verdict(
                ruby,
                normalize::bid_ask::<RubyDecimal>(&json).map_err(|e| norm(ruby, e))?,
                |(bid, ask)| {
                    let h = ruby.hash_new();
                    h.aset(sym("bid"), bid.value())?;
                    h.aset(sym("ask"), ask.value())?;
                    Ok(h.as_value())
                },
            ),
            other => Err(convert::shape(ruby, &format!("unknown finish op {other}"))),
        }
    }

    /// by_order: { otxid => [Ruby trade hashes] } in first-seen order → legacy aggregate hashes.
    fn aggregate_trades(ruby: &Ruby, by_order: RHash) -> Result<RHash, magnus::Error> {
        let out = ruby.hash_new();
        by_order.foreach(|otxid: Value, trades: RArray| {
            let mut json = Vec::with_capacity(trades.len());
            for i in 0..trades.len() {
                json.push(convert::to_json(ruby, trades.entry(i as isize)?)?); // Rust values only
            }
            let a = aggregate::<RubyDecimal>(&json).map_err(|e| norm(ruby, e))?;
            let first: Value = trades.entry(0)?;
            let times = ruby.ary_new();
            for i in 0..trades.len() {
                let t: Value = trades.entry(i as isize)?;
                let time: Value = t.funcall("[]", ("time",))?;
                times.push(time.funcall::<_, _, Value>("to_f", ())?)?;
            }
            let h = ruby.hash_new();
            h.aset(
                sym("order_id"),
                first.funcall::<_, _, Value>("[]", ("ordertxid",))?,
            )?;
            h.aset(sym("status"), sym("closed"))?;
            h.aset(
                sym("side"),
                a.side
                    .as_deref()
                    .map(sym)
                    .unwrap_or_else(|| ruby.qnil().as_value()),
            )?;
            h.aset(sym("order_type"), sym(a.order_type.as_str()))?;
            h.aset(sym("price"), opt_dec(ruby, &a.price))?;
            h.aset(sym("amount"), ruby.qnil())?;
            h.aset(sym("quote_amount"), ruby.qnil())?;
            h.aset(sym("amount_exec"), a.vol.value())?;
            h.aset(sym("quote_amount_exec"), a.cost.value())?;
            h.aset(sym("fee"), a.fee.value())?;
            h.aset(sym("pair"), first.funcall::<_, _, Value>("[]", ("pair",))?)?;
            h.aset(sym("trade_count"), trades.len())?;
            h.aset(
                sym("last_trade_at"),
                times.funcall::<_, _, Value>("max", ())?,
            )?;
            let raw = ruby.hash_new();
            raw.aset(ruby.str_new("trades"), trades)?;
            h.aset(sym("raw"), raw)?;
            out.aset(otxid, h)?;
            Ok(ForEach::Continue)
        })?;
        Ok(out)
    }

    fn classify_error(ruby: &Ruby, message: String) -> Result<Value, magnus::Error> {
        Ok(match normalize::classify_error(&message) {
            None => ruby.qnil().as_value(),
            Some((code, caps)) => {
                let h = ruby.hash_new();
                h.aset(sym("code"), sym(code))?;
                for (k, v) in caps {
                    h.aset(sym(k), ruby.str_new(&v))?;
                }
                h.as_value()
            }
        })
    }

    fn set_fixed_nonce(n: Option<u64>) {
        sign::set_fixed_nonce(n);
    }

    fn reset_nonce_state() {
        sign::reset_nonces();
    }
}

pub fn define(ruby: &Ruby, ext: magnus::RModule) -> Result<(), magnus::Error> {
    let c = ext.define_class("Kraken", ruby.class_object())?;
    c.define_singleton_method("new", magnus::function!(Kraken::new, 2))?;
    c.define_method("build_post", magnus::method!(Kraken::build_post, 2))?;
    c.define_method("sign", magnus::method!(Kraken::sign, 2))?;
    c.define_method("build_get", magnus::method!(Kraken::build_get, 2))?;
    c.define_singleton_method(
        "classify_error",
        magnus::function!(Kraken::classify_error, 1),
    )?;
    c.define_method("finish", magnus::method!(Kraken::finish, 2))?;
    c.define_singleton_method(
        "aggregate_trades",
        magnus::function!(Kraken::aggregate_trades, 1),
    )?;
    c.define_singleton_method(
        "fixed_nonce=",
        magnus::function!(Kraken::set_fixed_nonce, 1),
    )?;
    c.define_singleton_method(
        "reset_nonce_state!",
        magnus::function!(Kraken::reset_nonce_state, 0),
    )?;
    Ok(())
}
