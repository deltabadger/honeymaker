# frozen_string_literal: true

# Live, read-only comparison of honeymaker-client (examples/probe) against the gem on the real Kraken
# API, back to back. Places NO order: AddOrder runs only with validate=true, and only when
# KRAKEN_KEY_CAN_TRADE=1.
#   bundle exec ruby -Ilib script/parity/kraken_client_live.rb                          # public checks
#   KRAKEN_API_KEY=… KRAKEN_API_SECRET=… [KRAKEN_KEY_CAN_TRADE=1] [LOCAL_PROXY=1] \
#     bundle exec ruby -Ilib script/parity/kraken_client_live.rb
# The key must be one lent for this check, never a bot's key: nonces are per key.
require "honeymaker"
require "bigdecimal"
require "json"
require "open3"
require "securerandom"
require "socket"
require "time"

ROOT = File.expand_path("../..", __dir__)
system("cargo", "build", "--locked", "--quiet", "-p", "honeymaker-client", "--example", "probe", chdir: ROOT, exception: true)
PROBE = File.join(ROOT, "target/debug/examples/probe")
KEY = ENV["KRAKEN_API_KEY"]
SECRET = ENV["KRAKEN_API_SECRET"]
PRIVATE = !KEY.to_s.empty?
ASSET_MAP = Honeymaker::Clients::Kraken::ASSET_MAP
FAILURES = []

def rust(call, args, proxy)
  out, st = Open3.capture2(PROBE, stdin_data: JSON.generate({ call: call, args: args, proxy: proxy, api_key: KEY, api_secret: SECRET }))
  raise "probe failed" unless st.success?

  sleep 1 # Kraken's private counter decays ~0.33/s
  JSON.parse(out)
end

def legacy(proxy) = Honeymaker::Clients::Kraken.new(api_key: KEY, api_secret: SECRET, proxy: proxy)
def raw_post(proxy, path, params) = legacy(proxy).then { |c| c.send(:post_private, path, { nonce: c.send(:nonce), **params }) }.tap { sleep 1 }

def check(name, ok, detail = nil)
  puts "#{ok ? 'PASS' : 'FAIL'} #{name}#{" — #{detail}" if detail}"
  FAILURES << name unless ok
end

def d(x) = x.nil? ? nil : BigDecimal(x.to_s)

# deltabadger's get_balances for one asset: last matching entry wins (Ruling R9).
def rails_free(result, sym)
  result.reduce(BigDecimal("0")) do |free, (code, b)|
    base = code.split(".").first
    (ASSET_MAP[base] || base) == sym ? BigDecimal(b["balance"].to_s) - BigDecimal((b["hold_trade"] || "0").to_s) : free
  end
end

def run(proxy)
  tag = proxy ? " via CONNECT proxy" : ""
  l = legacy(proxy).get_ticker_information(pair: "XBTEUR")
  r = rust("prices", { pair: "XBTEUR" }, proxy)
  if l.success? && r["class"] == "ok"
    info = l.data["result"].values.first
    rp = r["value"].transform_values { |v| BigDecimal(v) }
    sane = rp.values.all?(&:positive?) && rp["bid"] <= rp["ask"]
    near = ((rp["last"] - BigDecimal(info["c"][0])).abs / rp["last"]) < BigDecimal("0.01")
    check("Ticker#{tag}", sane && near, "legacy last #{info['c'][0]}, rust last #{r['value']['last']}")
  else
    check("Ticker#{tag}", false, "legacy #{l.errors.inspect}, rust #{r.inspect}")
  end
  return unless PRIVATE

  bal = legacy(proxy).get_extended_balance.data["result"]
  syms = bal.keys.map { |c| b = c.split(".").first; ASSET_MAP[b] || b }.uniq | %w[EUR USD]
  syms.each do |sym|
    r = rust("balance", { asset: sym }, proxy)
    check("balance #{sym}#{tag}", r["class"] == "ok" && d(r["value"]) == rails_free(bal, sym), "#{r['value']} vs #{rails_free(bal, sym).to_s('F')}")
  end

  closed = raw_post(proxy, "/0/private/ClosedOrders", { ofs: 0 }).data["result"]
  txids = closed["closed"].keys.first(5)
  if txids.any?
    q = legacy(proxy).query_orders_info(txid: txids.join(",")).data
    r = rust("orders", { txids: txids }, proxy)
    same = r["class"] == "ok" && r["value"].all? do |o|
      g = q[o["txid"]]
      g && g[:status].to_s == o["status"] && d(g[:price]) == d(o["price"]) && d(g[:amount]) == d(o["amount"]) &&
        d(g[:quote_amount]) == d(o["quote_amount"]) && d(g[:amount_exec]) == d(o["amount_exec"]) &&
        d(g[:quote_amount_exec]) == d(o["quote_amount_exec"]) && (g[:order_type] == :limit) == o["limit"] &&
        (g[:side] == :sell) == o["sell"]
    end
    check("QueryOrders#{tag}", same && r["value"].size == q.size)

    since = Time.now.to_i - (90 * 86_400)
    lf = legacy(proxy).closed_orders_from_trades(order_ids: txids, start: since).data
    r = rust("fills_from_trades", { txids: txids, since: Time.at(since).utc.iso8601 }, proxy)
    same = r["class"] == "ok" && r["value"].size == lf.size && r["value"].all? do |o|
      a = lf[o["txid"]]
      a && d(a[:amount_exec]) == d(o["amount_exec"]) && d(a[:quote_amount_exec]) == d(o["quote_amount_exec"]) &&
        (a[:price].nil? ? o["price"].nil? : (d(o["price"]) - a[:price]).abs <= a[:price].abs * BigDecimal("1e-30"))
    end
    check("TradesHistory aggregate#{tag}", same)
  else
    puts "SKIP QueryOrders/TradesHistory: the account has no closed orders"
  end

  nobody = SecureRandom.uuid
  r = rust("order_by_client_id", { cl_ord_id: nobody, since: (Time.now.utc - 86_400).iso8601 }, proxy)
  check("order_by_client_id(unknown) is a complete absence#{tag}", r["class"] == "ok" && r["value"].nil?, r.inspect)
  filtered = raw_post(proxy, "/0/private/ClosedOrders", { cl_ord_id: nobody, ofs: 0 }).data["result"]
  if closed["count"].to_i.positive?
    check("ClosedOrders honours the cl_ord_id filter#{tag}", filtered["count"].to_i.zero? && filtered["closed"].to_h.empty?)
  else
    puts "SKIP cl_ord_id filter proof: the account has no closed orders"
  end
  if ENV["KRAKEN_KNOWN_CL_ORD_ID"] && ENV["KRAKEN_KNOWN_TXID"]
    r = rust("order_by_client_id", { cl_ord_id: ENV["KRAKEN_KNOWN_CL_ORD_ID"], since: (Time.now.utc - (30 * 86_400)).iso8601 }, proxy)
    check("order_by_client_id finds a real order#{tag}", r["class"] == "ok" && r.dig("value", "txid") == ENV["KRAKEN_KNOWN_TXID"], r.inspect)
  end

  return unless ENV["KRAKEN_KEY_CAN_TRADE"] == "1"

  deadline = -> { (Time.now.utc + 30).iso8601(3) }
  l = legacy(proxy).add_order(ordertype: "market", type: "buy", volume: "0.0001", pair: "XBTEUR",
                              cl_ord_id: SecureRandom.uuid, deadline: deadline.call, validate: true)
  sleep 1
  r = rust("add_order_validate", { pair: "XBTEUR", kind: "market", volume: "0.0001", quote_volume: false,
                                   cl_ord_id: SecureRandom.uuid, deadline: deadline.call }, proxy)
  check("AddOrder validate=true with cl_ord_id and deadline#{tag}", l.success? && r["class"] == "ok", "legacy #{l.errors.inspect}, rust #{r.inspect}")
end

# A local CONNECT proxy that only tunnels to api.kraken.com:443, recording each CONNECT line.
def local_proxy
  seen = []
  tcp = TCPServer.new("127.0.0.1", 0)
  Thread.new do
    loop do
      s = tcp.accept
      Thread.new do
        head = +""
        head << s.readpartial(4096) until head.include?("\r\n\r\n")
        line = head.lines.first.strip
        seen << line
        raise "refused #{line}" unless line == "CONNECT api.kraken.com:443 HTTP/1.1"

        up = TCPSocket.new("api.kraken.com", 443)
        s.write "HTTP/1.1 200 Connection established\r\n\r\n"
        t = Thread.new { IO.copy_stream(s, up) rescue nil; up.close_write rescue nil }
        IO.copy_stream(up, s) rescue nil
        t.join(1)
      rescue StandardError
        nil
      ensure
        s.close rescue nil
      end
    end
  end
  ["http://127.0.0.1:#{tcp.addr[1]}", seen]
end

puts "private checks: #{PRIVATE ? 'on' : 'off (no key)'}; AddOrder validate: #{ENV['KRAKEN_KEY_CAN_TRADE'] == '1' ? 'on' : 'off'}"
run(nil)
if ENV["LOCAL_PROXY"] == "1"
  url, seen = local_proxy
  run(url)
  check("both backends tunnelled through the proxy", seen.size >= 2 && seen.uniq == ["CONNECT api.kraken.com:443 HTTP/1.1"], seen.inspect)
end
abort "FAILED: #{FAILURES.join(', ')}" if FAILURES.any?
puts "live comparison passed"
