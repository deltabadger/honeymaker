//! Drives the Kraken client from one JSON request on stdin and prints the outcome as JSON. The
//! Ruby parity and live scripts run it next to the gem. Not a public interface.
use bigdecimal::BigDecimal;
use chrono::{DateTime, Utc};
use honeymaker_client::kraken::{
    Client, Config, Credentials, DEFAULT_URL, NewOrder, OrderKind, OrderState, OrderStatus,
    VenueError,
};
use honeymaker_client::transport::Timeouts;
use rustls::pki_types::{CertificateDer, pem::PemObject};
use serde_json::{Value, json};
use std::io::Read;
use std::sync::Arc;
use std::time::{Duration, Instant};

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let req: Value = serde_json::from_str(&input).unwrap();
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    println!("{}", rt.block_on(run(&req)));
}

fn d(x: &BigDecimal) -> Value {
    json!(x.to_plain_string())
}
fn state(o: &OrderState) -> Value {
    let status = match o.status {
        OrderStatus::Unknown => "unknown",
        OrderStatus::Open => "open",
        OrderStatus::Closed => "closed",
        OrderStatus::Cancelled => "cancelled",
    };
    json!({ "txid": o.txid, "status": status, "price": o.price.as_ref().map(d), "amount": o.amount.as_ref().map(d),
            "quote_amount": o.quote_amount.as_ref().map(d), "amount_exec": d(&o.amount_exec),
            "quote_amount_exec": d(&o.quote_amount_exec), "limit": o.limit, "sell": o.sell })
}
fn strings(v: &Value) -> Vec<String> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|s| s.as_str().unwrap().to_string())
        .collect()
}
fn time(v: &Value) -> DateTime<Utc> {
    v.as_str().unwrap().parse().unwrap()
}
fn order(a: &Value) -> NewOrder {
    NewOrder {
        pair: a["pair"].as_str().unwrap().into(),
        kind: match a["kind"].as_str().unwrap() {
            "limit" => OrderKind::Limit {
                price: a["price"].as_str().unwrap().into(),
            },
            _ => OrderKind::Market,
        },
        volume: a["volume"].as_str().unwrap().into(),
        quote_volume: a["quote_volume"].as_bool().unwrap_or(false),
        cl_ord_id: a["cl_ord_id"].as_str().unwrap().into(),
        deadline: time(&a["deadline"]),
    }
}

async fn run(req: &Value) -> Value {
    let configured = Instant::now();
    if let Some(n) = req["fixed_nonce"].as_u64() {
        honeymaker::kraken::sign::set_fixed_nonce(Some(n));
    }
    let secs = |i: usize, default: f64| {
        Duration::from_secs_f64(req["timeouts"][i].as_f64().unwrap_or(default))
    };
    let tls_roots = req["ca_pem"].as_str().map(|path| {
        let mut store = rustls::RootCertStore::empty();
        for c in CertificateDer::pem_file_iter(path).unwrap() {
            store.add(c.unwrap()).unwrap();
        }
        Arc::new(store)
    });
    let credentials = req["api_key"].as_str().map(|k| Credentials {
        api_key: k.into(),
        api_secret: req["api_secret"].as_str().unwrap_or("").into(),
    });
    let config = Config {
        base_url: req["base_url"].as_str().unwrap_or(DEFAULT_URL).into(),
        proxy: req["proxy"].as_str().map(str::to_string),
        timeouts: Timeouts {
            open: secs(0, 5.0),
            read: secs(1, 30.0),
            write: secs(2, 10.0),
        },
        credentials,
        tls_roots,
        ..Config::default()
    };
    let client = match Client::new(config) {
        Ok(c) => c,
        Err(e) => {
            return json!({ "class": "config", "message": e.to_string(), "ms": configured.elapsed().as_millis() as u64 });
        }
    };
    let a = &req["args"];
    let started = Instant::now();
    let result: Result<Value, VenueError> = match req["call"].as_str().unwrap() {
        "prices" => client
            .prices(a["pair"].as_str().unwrap())
            .await
            .map(|p| json!({ "bid": d(&p.bid), "ask": d(&p.ask), "last": d(&p.last) })),
        "add_order" => client.add_order(&order(a)).await.map(Value::from),
        "add_order_validate" => client
            .add_order_validate(&order(a))
            .await
            .map(|()| Value::Bool(true)),
        "orders" => client
            .orders(&strings(&a["txids"]))
            .await
            .map(|v| Value::Array(v.iter().map(state).collect())),
        "order_by_client_id" => client
            .order_by_client_id(a["cl_ord_id"].as_str().unwrap(), time(&a["since"]))
            .await
            .map(|o| o.as_ref().map(state).unwrap_or(Value::Null)),
        "fills_from_trades" => client
            .fills_from_trades(&strings(&a["txids"]), time(&a["since"]))
            .await
            .map(|v| Value::Array(v.iter().map(state).collect())),
        "balance" => client
            .balance(a["asset"].as_str().unwrap())
            .await
            .map(|b| d(&b)),
        other => panic!("unknown call {other}"),
    };
    let ms = started.elapsed().as_millis() as u64;
    match result {
        Ok(value) => json!({ "class": "ok", "value": value, "ms": ms }),
        Err(VenueError::Rejected(errors)) => {
            json!({ "class": "rejected", "errors": errors, "ms": ms })
        }
        Err(VenueError::Ambiguous(m)) => json!({ "class": "ambiguous", "message": m, "ms": ms }),
        Err(VenueError::Transient(m)) => json!({ "class": "transient", "message": m, "ms": ms }),
    }
}
