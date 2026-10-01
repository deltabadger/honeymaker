# frozen_string_literal: true

# Regenerates the stage-2 vectors from the LEGACY Ruby implementation.
#   bundle exec ruby -Ilib script/vectors/kraken_stage2.rb
require "honeymaker"
require "json"
require "faraday"

OUT = File.expand_path("../../crates/honeymaker/tests/vectors", __dir__)
SECRET = Base64.strict_encode64("test_secret_key_1234567890123456")
NONCE = 1_727_000_000_000_001

def legacy
  c = Honeymaker::Clients::Kraken.new(api_key: "key", api_secret: SECRET)
  c.define_singleton_method(:nonce) { NONCE }
  c
end

# --- A: AddOrder with cl_ord_id and deadline, as legacy signs and sends it ---
orders = [
  { ordertype: "market", type: "buy", volume: "0.0012", pair: "XBTEUR", oflags: ["viqc"],
    cl_ord_id: "6f1c1a52-7c8e-4d0e-9a57-0b6f0f1d2e3a", deadline: "2026-09-30T12:00:10.000Z" },
  { ordertype: "limit", type: "buy", volume: "0.00119", pair: "XBTEUR", price: "49870.1", oflags: [],
    cl_ord_id: "0d9e2c1b-2f4a-4b8c-8d1e-5a6b7c8d9e0f", deadline: "2026-09-30T12:00:10.123Z" },
  { ordertype: "market", type: "buy", volume: "60", pair: "XBTEUR", oflags: ["viqc"],
    cl_ord_id: "6f1c1a52-7c8e-4d0e-9a57-0b6f0f1d2e3a", deadline: "2026-09-30T12:00:10.000Z", validate: true }
]
wire = orders.map do |args|
  body = nil
  stubs = Faraday::Adapter::Test::Stubs.new do |s|
    s.post("/0/private/AddOrder") do |env|
      body = env.body
      [200, { "Content-Type" => "application/json" }, '{"error":[],"result":{"txid":["OTX-1"]}}']
    end
  end
  c = legacy
  c.instance_variable_set(:@connection, Faraday.new(url: Honeymaker::Clients::Kraken::URL) { |f| f.response :json; f.adapter :test, stubs })
  raise "legacy did not answer" unless c.add_order(**args).success?

  { args: args, nonce: NONCE, api_key: "key", api_secret: SECRET, body: body,
    headers: c.send(:private_headers, "/0/private/AddOrder", body).transform_keys(&:to_s) }
end
File.write(File.join(OUT, "kraken_add_order_wire.json"), JSON.pretty_generate(wire))
puts "wrote #{wire.size} AddOrder wire vectors"

# --- B: closed_orders_from_trades, the verbatim Ruby loop (with Task 8's dedupe), over scripted
# pages. Each case says what the STRICT Rust scan must do: "same" as Ruby (a completed scan, a
# refusal, an unreadable page or a Ruby exception), "incomplete" where Ruby stopped early or
# trusted a malformed container and returned what it had, or "error" where Ruby skipped a malformed
# record that Rust must refuse. The label is what Rust must do, not what Ruby did: some
# "incomplete" cases are Ruby raises (NoMethodError on trades as a non-empty array, a non-empty
# string or a number, and on count true or an array), not partial answers. Their "outcome" says so.
def page(trades, count = :none)
  result = { "trades" => trades }
  result["count"] = count unless count == :none
  { "error" => [], "result" => result }
end

def trade(o, vol, cost, type: "buy", ordertype: "market", fee: "0.1")
  { "ordertxid" => o, "vol" => vol, "cost" => cost, "fee" => fee, "type" => type, "ordertype" => ordertype, "time" => 1.5 }
end

T = ->(i, o = "O1") { { "T#{i}" => trade(o, "1", "2") } }
cases = [
  ["one page", :same, %w[O1], 1_700_000_000, 20, [page({ "T1" => trade("O1", "0.0006", "30"), "T2" => trade("O1", "0.0006", "30") }, 2)]],
  ["partial fill across pages, unwanted skipped", :same, %w[O1 O2], 1_700_000_000, 20,
   [page({ "T1" => trade("O1", "1", "2"), "T2" => trade("O9", "1", "2") }, 3),
    page({ "T3" => trade("O1", "1", "2"), "T4" => trade("O2", "2", "8", ordertype: "limit", type: "sell") }, 3)]],
  ["no wanted ids: no request", :same, [], nil, 20, []],
  ["a trade on two pages: rows reach count, distinct trades do not", :incomplete, %w[O1], nil, 20,
   [page({ "T1" => trade("O1", "1", "2"), "T2" => trade("O1", "3", "9") }, 3), page({ "T2" => trade("O1", "3", "9") }, 3)]],
  ["overlapping pages that cover every trade", :same, %w[O1], nil, 20,
   [page({ "T1" => trade("O1", "1", "2"), "T2" => trade("O1", "3", "9") }, 3),
    page({ "T2" => trade("O1", "3", "9"), "T3" => trade("O1", "1", "1") }, 3)]],
  ["complete exactly at the page cap", :same, %w[O1], nil, 2, [page(T[1], 2), page(T[2], 2)]],
  ["an empty page after the last trade", :same, %w[O1], nil, 20, [page({}, 0)]],
  ["a fill beyond the page cap", :incomplete, %w[O1], nil, 2, [page(T[1, "O9"], 3), page(T[2, "O9"], 3), page(T[3], 3)]],
  ["count as a string", :incomplete, %w[O1], nil, 20, [page(T[1], "2"), page(T[2], "2")]],
  ["count 1_000 pages to max_pages", :incomplete, %w[O1], nil, 2, [page(T[1], "1_000"), page(T[2], "1_000"), page(T[3], "1_000")]],
  ["bignum string count", :incomplete, %w[O1], nil, 3, [page(T[1], "99999999999999999999999"), page(T[2], "1"), page(T[3], "1")]],
  ["bignum integer count", :incomplete, %w[O1], nil, 3, [page(T[1], 10**25), page(T[2], 10**25), page(T[3], 10**25), page(T[4], 10**25)]],
  ["float count", :incomplete, %w[O1], nil, 20, [page(T[1], 2.9), page(T[2], 2.9), page(T[3], 2.9)]],
  ["missing count", :incomplete, %w[O1], nil, 20, [page(T[1]), page(T[2])]],
  ["nil count", :incomplete, %w[O1], nil, 20, [page(T[1], nil), page(T[2])]],
  ["negative count", :incomplete, %w[O1], nil, 20, [page(T[1], -1), page(T[2])]],
  *[" 3", "3abc", "0x10", "_3", "3__0", "+3", "-3", "", "abc"].map do |c|
    ["count #{c.inspect}", :incomplete, %w[O1], nil, 4, (1..4).map { |i| page(T[i], c) }]
  end,
  ["empty trades before count", :incomplete, %w[O1], nil, 20, [page({}, 5), page(T[1], 5)]],
  ["missing trades", :incomplete, %w[O1], nil, 20, [{ "error" => [], "result" => { "count" => 3 } }, page(T[1])]],
  ["trades false", :incomplete, %w[O1], nil, 20, [page(false, 3), page(T[1])]],
  ["trades []", :incomplete, %w[O1], nil, 20, [page([], 3), page(T[1])]],
  ["trades \"\"", :incomplete, %w[O1], nil, 20, [page("", 3), page(T[1])]],
  ["nil result", :incomplete, %w[O1], nil, 20, [{ "error" => [] }, page(T[1])]],
  ["result as a string raises", :same, %w[O1], nil, 20, [{ "error" => [], "result" => "x" }]],
  ["result as an array raises", :same, %w[O1], nil, 20, [{ "error" => [], "result" => [1] }]],
  ["result false raises", :same, %w[O1], nil, 20, [{ "error" => [], "result" => false }]],
  ["trades as a non-empty array", :incomplete, %w[O1], nil, 20, [page([1], 1)]],
  ["trades as a non-empty string", :incomplete, %w[O1], nil, 20, [page("x", 1)]],
  ["trades as a number", :incomplete, %w[O1], nil, 20, [page(5, 1)]],
  *[[false, "false"], [[], "[]"], ["", "\"\""], [nil, "null"]].map do |trades, label|
    ["trades #{label} with count 0", :incomplete, %w[O1], nil, 20, [page(trades, 0)]]
  end,
  ["trades missing with count 0", :incomplete, %w[O1], nil, 20, [{ "error" => [], "result" => { "count" => 0 } }]],
  ["a trade that is a string", :error, %w[O1], nil, 20, [page({ "T1" => "no id here", "T2" => trade("O1", "1", "2") }, 2)]],
  ["a record without ordertxid", :error, %w[O1], nil, 20, [page({ "T1" => { "vol" => "1", "cost" => "2" } }, 1)]],
  ["a record with a numeric ordertxid", :error, %w[O1], nil, 20, [page({ "T1" => trade(5, "1", "2") }, 1)]],
  ["a trade that is a number raises", :same, %w[O1], nil, 20, [page({ "T1" => 5 }, 1)]],
  ["a trade that is null raises", :same, %w[O1], nil, 20, [page({ "T1" => nil }, 1)]],
  ["count true", :incomplete, %w[O1], nil, 20, [page(T[1], true)]],
  ["count as an array", :incomplete, %w[O1], nil, 20, [page(T[1], [1])]],
  ["refusal on page 2", :same, %w[O1], nil, 20, [page(T[1], 5), { "error" => ["EAPI:Rate limit exceeded"] }]],
  ["falsy errors are not a refusal", :same, %w[O1], nil, 20, [{ "error" => [nil, false], "result" => { "trades" => T[1], "count" => 1 } }]],
  ["non-object page 2 is unreadable", :same, %w[O1], nil, 20, [page(T[1], 5), "oops"]],
  ["pages run out: legacy sees null", :same, %w[O1], nil, 20, [page(T[1], 5)]],
  ["zero volume has no price", :same, %w[O1], nil, 20, [page({ "T1" => trade("O1", "0", "0") }, 1)]]
]

pager = cases.map do |name, strict, ids, start, max_pages, pages|
  texts = pages.map { |p| JSON.generate(p) }
  queue = texts.dup
  requests = []
  c = legacy
  c.define_singleton_method(:get_trades_history) do |start: nil, ofs: nil, **|
    requests << [start, ofs]
    Honeymaker::Result::Success.new(JSON.parse(queue.shift || "null"))
  end
  outcome = begin
    r = c.closed_orders_from_trades(order_ids: ids, start: start, max_pages: max_pages)
    if r.success?
      { "ok" => r.data.map do |txid, a|
        [txid, { "vol" => a[:amount_exec].to_s("F"), "cost" => a[:quote_amount_exec].to_s("F"), "fee" => a[:fee].to_s("F"),
                 "price" => a[:price]&.to_s("F"), "side" => a[:side]&.to_s, "order_type" => a[:order_type].to_s }]
      end }
    elsif r.data.is_a?(Hash) && r.data[:unreadable]
      { "unreadable" => true }
    else
      { "venue" => r.errors }
    end
  rescue StandardError => e
    { "raise" => e.class.name }
  end
  { name: name, strict: strict, order_ids: ids, start: start, max_pages: max_pages, pages: texts, requests: requests, outcome: outcome }
end
File.write(File.join(OUT, "kraken_trades_pager.json"), JSON.pretty_generate(pager))
puts "wrote #{pager.size} trades-pager vectors"
