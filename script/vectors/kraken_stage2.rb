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
