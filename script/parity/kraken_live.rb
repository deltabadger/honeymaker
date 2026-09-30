# frozen_string_literal: true

# Read-only live comparison, legacy vs native, back to back against the real Kraken API.
#   KRAKEN_API_KEY=… KRAKEN_API_SECRET=… KRAKEN_TXIDS=O1,O2 bundle exec ruby -Ilib script/parity/kraken_live.rb
# Places NO order: AddOrder runs with validate: true.
require "honeymaker"
Honeymaker::Native.load!
require "honeymaker/native/kraken"

# Public checks always run (no key needed). Private checks run only with a key that is OURS or
# lent for this purpose (a separate key: Kraken nonces are per key, so a bot's own key would race).
key, secret, proxy = ENV["KRAKEN_API_KEY"], ENV["KRAKEN_API_SECRET"], ENV["PROXY"]
private_checks = !key.to_s.empty?
txids = ENV.fetch("KRAKEN_TXIDS", "").split(",").reject(&:empty?)
abort "KRAKEN_TXIDS must name at least one order when a key is given" if private_checks && txids.empty?
trade = ENV["KRAKEN_KEY_CAN_TRADE"] == "1" # only then run AddOrder validate: true
legacy = Honeymaker::Clients::Kraken.new(api_key: key, api_secret: secret, proxy: proxy)
native = Honeymaker::Native::KrakenClient.new(api_key: key, api_secret: secret, proxy: proxy)

def shape(v)
  case v
  when Hash then v.to_h { |k, x| [k, shape(x)] }
  when Array then v.map { |x| shape(x) }
  else v.class
  end
end

# A raw Kraken envelope that really answered: error == [] and a non-empty result of the given class.
def envelope?(d, klass = Hash)
  d.is_a?(Hash) && d["error"] == [] && d["result"].is_a?(klass) && !d["result"].empty?
end

DYNAMIC = { "GetApiKeyInfo" => ->(d) { d.merge("result" => d["result"].except("nonce", "lastUsed")) } }.freeze

RAW = ->(d) { envelope?(d) }
checks = [
  [:equal, "AssetPairs", ->(c) { c.get_tradable_asset_pairs(aclass_base: "all") }, RAW],
  [:equal, "Assets", ->(c) { c.get_asset_info }, RAW],
  [:equal, "BalanceEx", ->(c) { c.get_extended_balance }, RAW],
  [:equal, "balances", ->(c) { c.get_balances }, ->(d) { d.is_a?(Hash) && d.values.all? { |b| b[:free].is_a?(BigDecimal) } }],
  [:equal, "GetApiKeyInfo", ->(c) { c.get_api_key_info }, RAW],
  [:equal, "TradesHistory", ->(c) { c.get_trades_history }, ->(d) { envelope?(d) && d["result"]["trades"].is_a?(Hash) }],
  [:equal, "Ledgers", ->(c) { c.get_ledgers }, ->(d) { envelope?(d) && d["result"]["ledger"].is_a?(Hash) }],
  [:equal, "QueryOrders", ->(c) { c.query_orders_info(txid: txids.join(",")) }, ->(d) { d.is_a?(Hash) && txids.all? { |t| d.key?(t) } }],
  [:equal, "closed_orders_from_trades", ->(c) { c.closed_orders_from_trades(order_ids: txids, start: Time.now.to_i - (90 * 86_400)) }, ->(d) { d.is_a?(Hash) }],
  [:equal, "validate", ->(c) { c.validate(:trading) }, ->(d) { d == true }],
  [:shape, "Ticker", ->(c) { c.get_ticker_information(pair: "XBTUSD") }, RAW],
  [:shape, "OHLC", ->(c) { c.get_ohlc_data(pair: "XBTUSD", interval: 1440) }, RAW],
  [:shape, "AddOrder validate", ->(c) { c.add_order(ordertype: "market", type: "buy", volume: "0.0001", pair: "XBTUSD", validate: true) },
   ->(d) { d.is_a?(Hash) && envelope?(d[:raw]) && d[:raw]["result"]["descr"].is_a?(Hash) }]
]

failures = 0
public_names = %w[AssetPairs Assets Ticker OHLC]
checks.select! { |_, name, _, _| public_names.include?(name) || private_checks }
checks.reject! { |_, name, _, _| name == "AddOrder validate" && !trade }
puts "private checks: #{private_checks ? 'on' : 'off (no key)'}; AddOrder validate: #{trade ? 'on' : 'off'}"
checks.each do |mode, name, call, valid|
  l = call.call(legacy)
  sleep 1 # Kraken's private counter decays ~0.33/s; keep the pair adjacent but polite
  n = call.call(native)
  norm = DYNAMIC.fetch(name, ->(d) { d })
  ok = l.success? && n.success? && valid.call(l.data) && valid.call(n.data) &&
       (mode == :equal ? norm.call(l.data) == norm.call(n.data) : shape(l.data) == shape(n.data))
  failures += 1 unless ok
  puts format("%-26s %-5s %s", name, mode, ok ? "OK" : "FAIL\n  legacy=#{l.inspect[0, 500]}\n  native=#{n.inspect[0, 500]}")
  sleep 1
end
puts failures.zero? ? "LIVE PARITY PASSED" : "LIVE PARITY FAILED: #{failures}"
exit(failures.zero? ? 0 : 1)
