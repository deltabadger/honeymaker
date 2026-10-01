# frozen_string_literal: true

require "test_helper"
require "support/parity_helper"

class KrakenClientParityTest < Minitest::Test
  include ParityHelper

  NONCE = 1_727_000_000_000_001
  SECRET = Base64.strict_encode64("test_secret_key_1234567890123456")
  JSON_CT = { "content-type" => "application/json" }.freeze
  SIGNED = %w[api-key api-sign content-type accept user-agent accept-encoding].freeze

  def teardown
    Honeymaker::Native::Ext::Kraken.fixed_nonce = nil if defined?(Honeymaker::Native::Ext::Kraken)
    super
  end

  def clients(key, secret, url)
    [Honeymaker::Clients::Kraken, Honeymaker::Native::KrakenClient].map do |k|
      k.new(api_key: key, api_secret: secret).tap do |c|
        c.instance_variable_set(:@connection, c.send(:build_client_connection, url))
      end
    end
  end

  # Legacy then native against ONE double (same URL); returns [lr, nr, lreqs, nreqs].
  def run_both(replies, key: "test_key", secret: SECRET)
    Honeymaker::Clients::Kraken.any_instance.stubs(:nonce).returns(NONCE)
    Honeymaker::Native::Ext::Kraken.fixed_nonce = NONCE
    d = VenueDouble.new(replies)
    legacy, native = clients(key, secret, d.url)
    lr = begin; yield(legacy); rescue StandardError => e; e; end
    lq = d.requests
    d.reset!(replies)
    nr = begin; yield(native); rescue StandardError => e; e; end
    [lr, nr, lq, d.requests]
  ensure
    d&.close
  end

  def assert_same_requests(legacy, native)
    assert_equal legacy.size, native.size, "request count"
    legacy.zip(native).each do |l, n|
      assert_equal [l.method, l.target, l.body], [n.method, n.target, n.body]
      assert_equal l.headers.slice(*SIGNED), n.headers.slice(*SIGNED)
    end
  end

  def assert_parity(replies, **kw, &call)
    lr, nr, lq, nq = run_both(replies, **kw, &call)
    assert_same_ruby(lr, nr)
    assert_same_requests(lq, nq)
  end

  def ok(result) = [200, JSON_CT, { "error" => [], "result" => result }.to_json]
  def venue(*errors) = [200, JSON_CT, { "error" => errors, "result" => {} }.to_json]

  COMMON = [
    [500, JSON_CT, '{"error":["EService:Unavailable"]}'],
    [500, { "content-type" => "text/plain" }, ""],
    [200, { "content-type" => "text/html" }, "<html>maintenance</html>"],
    [200, JSON_CT, ""],
    [200, JSON_CT, "null"],
    [200, JSON_CT, "{not json"],
    [200, JSON_CT, '{"error":[],"result":{"dup":1,"dup":2}}'],
    [200, JSON_CT, '{"error":["EGeneral:Invalid arguments"],"result":{}}'],
    [200, JSON_CT, '{"error":[null,false],"result":{}}']
  ].freeze

  def each_reply(*specific, &blk) = (specific + COMMON).each { |r| blk.call(r) }

  def test_get_extended_balance_and_get_balances
    bal = { "XXBT" => { "balance" => "0.5000000000", "hold_trade" => "0.1" }, "ZEUR" => { "balance" => "10.5" },
            "USDT.F" => { "balance" => "0", "hold_trade" => "0" }, "XXDG" => { "balance" => 12_345_678_901_234_567_890 },
            "BONK" => { "balance" => 0.1 }, "ETH2.S" => { "balance" => "1e-9" }, "NEG" => { "balance" => "-0.0000", "hold_trade" => "0.1" },
            "" => { "balance" => "1" }, "..." => { "balance" => "2" } }
    each_reply(ok(bal), venue("EAPI:Invalid key"), ok({ "X" => { "balance" => nil } }), ok({ "X" => { "balance" => "NaN" } }), ok([]), ok(["x"])) do |reply|
      assert_parity([reply], &:get_extended_balance)
      assert_parity([reply], &:get_balances)
    end
  end

  def test_query_orders_info
    orders = {
      "O1" => { "status" => "closed", "descr" => { "type" => "BUY", "ordertype" => "market", "price" => "0" },
                "vol" => "10", "vol_exec" => "10", "cost" => "500.5", "price" => "50.05", "oflags" => "fciq,viqc" },
      "O2" => { "status" => "open", "descr" => { "type" => "sell", "ordertype" => "limit", "price" => "60000" },
                "vol" => "0.01", "vol_exec" => "0", "cost" => "0", "price" => "0", "oflags" => "" },
      "O3" => { "status" => "expired", "descr" => { "ordertype" => "stop-loss" }, "vol" => "1", "vol_exec" => "0",
                "cost" => "0", "price" => "0" },
      "O4" => { "status" => "pending", "descr" => false, "vol" => 1, "vol_exec" => 0.5, "cost" => "0", "price" => "0" }
    }
    each_reply(ok(orders), ok({}), ok([]), ok(["x"])) do |reply|
      assert_parity([reply]) { |c| c.query_orders_info(txid: "O1,O2,O3,O4") }
      assert_parity([reply]) { |c| c.query_orders_info(txid: "O1", trades: true, userref: 7, consolidate_taker: false) }
    end
  end

  def test_add_order_and_cancel
    each_reply(ok({ "txid" => ["OX-1"], "descr" => { "order" => "buy 1 XBTUSD" } }), ok({ "descr" => {} }), ok({ "txid" => [] })) do |reply|
      assert_parity([reply]) { |c| c.add_order(ordertype: "market", type: "buy", volume: "0.001", pair: "XBTUSDT", oflags: ["viqc"]) }
      assert_parity([reply]) do |c|
        c.add_order(ordertype: "limit", type: "sell", volume: BigDecimal("0.001"), pair: "XBTUSDT", price: "60000.1",
                    close: "limit", close_price: "61000", validate: true, userref: 42, timeinforce: "GTC", oflags: [])
      end
      assert_parity([reply]) { |c| c.cancel_order(txid: "OX-1") }
    end
  end

  def test_public_endpoints
    each_reply(ok({ "XXBTZUSD" => { "a" => ["50000.1", "1", "1.000"], "b" => ["50000.0", "2", "2.000"] } })) do |reply|
      assert_parity([reply]) { |c| c.get_ticker_information(pair: "XBTUSD") }
      assert_parity([reply], &:get_ticker_information)
      assert_parity([reply]) { |c| c.get_tradable_asset_pairs(pairs: %w[XBTUSD ETHUSD], aclass_base: "all") }
      assert_parity([reply]) { |c| c.get_tradable_asset_pairs(pairs: []) }
      assert_parity([reply]) { |c| c.get_asset_info(assets: %w[XBT], aclass: "currency") }
      assert_parity([reply]) { |c| c.get_ohlc_data(pair: "XBTUSD", interval: 60, since: 1_700_000_000) }
    end
  end

  def test_other_private_endpoints
    each_reply(ok({ "count" => 1 })) do |reply|
      assert_parity([reply], &:get_api_key_info)
      assert_parity([reply]) { |c| c.get_trades_history(type: "all", start: 1, end_time: 2, ofs: 50) }
      assert_parity([reply]) { |c| c.get_ledgers(asset: "XBT", start: 1, end_time: 2, ofs: 0) }
      assert_parity([reply]) { |c| c.get_withdraw_addresses(asset: "XBT", method: "Bitcoin") }
      assert_parity([reply], &:get_withdraw_methods)
      assert_parity([reply]) { |c| c.withdraw(asset: "XBT", key: "my key", amount: "0.01", address: "bc1q\u2026") }
      assert_parity([reply]) { |c| c.get_earn_allocations(ascending: true, converted_asset: "USD", hide_zero_allocations: false) }
    end
  end

  def page(trades, count)
    ok({ "trades" => trades.to_h { |t| [t[:id], { "ordertxid" => t[:o], "type" => "buy", "ordertype" => "market",
                                                   "vol" => t[:vol], "cost" => t[:cost], "fee" => "0.01",
                                                   "pair" => "XXBTZUSD", "time" => t[:time] }] }, "count" => count })
  end

  def test_closed_orders_from_trades
    p1 = page([{ id: "T1", o: "O1", vol: "0.1", cost: "5000", time: 1_700_000_000.1234 },
               { id: "T2", o: "OX", vol: "1", cost: "1", time: 1_700_000_001 }], 3)
    p2 = page([{ id: "T3", o: "O1", vol: "0.2", cost: "10001", time: "1700000002.5" }], "3")
    assert_parity([p1, p2]) { |c| c.closed_orders_from_trades(order_ids: %w[O1 O2], start: 1_699_000_000) }
    assert_parity([p1, p2]) { |c| c.closed_orders_from_trades(order_ids: "O1", max_pages: 1) }
    assert_parity([page([{ id: "T9", o: "O1", vol: "-0", cost: "0", time: 1 }], 1)]) { |c| c.closed_orders_from_trades(order_ids: %w[O1]) }
    COMMON.each { |bad| assert_parity([p1, bad]) { |c| c.closed_orders_from_trades(order_ids: %w[O1]) } }
    # Malformed pages must raise like legacy, never return partial fills (Codex r2 #1).
    ['{"error":[],"result":false}', '{"error":[],"result":"oops"}', '{"error":[],"result":{"trades":{"T5":null},"count":9}}',
     '{"error":[],"result":{"trades":[1],"count":9}}',
     '{"error":[],"result":{"trades":{"T6":{"ordertxid":"O1","vol":"1","cost":"1","fee":"0","time":1}},"count":true}}',
     '{"error":[],"result":{"trades":[],"count":9}}', '{"error":[],"result":null}'].each do |bad|
      assert_parity([p1, [200, JSON_CT, bad]]) { |c| c.closed_orders_from_trades(order_ids: %w[O1]) }
      assert_parity([[200, JSON_CT, bad]]) { |c| c.closed_orders_from_trades(order_ids: %w[O1]) }
    end
    assert_parity([ok({ "trades" => {}, "count" => 0 })]) { |c| c.closed_orders_from_trades(order_ids: %w[O1]) }
    assert_parity([p1]) { |c| c.closed_orders_from_trades(order_ids: []) }
  end

  def test_closed_orders_from_trades_counts_a_trade_seen_on_two_pages_once
    t1 = { id: "T1", o: "O1", vol: "0.1", cost: "5000", time: 1_700_000_000 }
    t2 = { id: "T2", o: "O1", vol: "0.2", cost: "10001", time: 1_700_000_001 }
    p1 = page([t1, t2], 3)
    p2 = page([t2], 3)
    assert_parity([p1, p2]) { |c| c.closed_orders_from_trades(order_ids: %w[O1], start: 1_699_000_000) }
  end

  def test_aggregate_edges
    [{ "type" => false }, { "type" => 1 }, { "type" => nil }, { "ordertype" => 5 }].each do |over|
      bad_page = page([{ id: "T1", o: "O1", vol: "1", cost: "2", time: 1 }], 1)
      body = JSON.parse(bad_page[2])
      body["result"]["trades"]["T1"].merge!(over)
      assert_parity([[200, JSON_CT, body.to_json]]) { |c| c.closed_orders_from_trades(order_ids: %w[O1]) }
    end
    assert_parity([page([{ id: "T1", o: "O1", vol: "1", cost: "2", time: 1 }], "1_000"),
                   page([{ id: "T2", o: "O1", vol: "1", cost: "2", time: 2 }], "99999999999999999999999")]) do |c|
      c.closed_orders_from_trades(order_ids: %w[O1], max_pages: 2)
    end
  end

  def test_validate
    [ok({ "XXBT" => { "balance" => "1" } }), venue("EAPI:Invalid key"), [403, JSON_CT, "{}"],
     [200, { "content-type" => "text/html" }, "x"], [200, JSON_CT, '{"error":[null]}']].each do |reply|
      assert_parity([reply]) { |c| c.validate(:trading) }
      assert_parity([reply]) { |c| c.validate(:read) }
    end
    assert_parity([ok({})], key: "", &:validate)
    assert_parity([ok({})]) { |c| c.validate(:bogus) }
    ["", "null", "[1]", "5", "true", '"abc"', '"error"'].each do |body|
      assert_parity([[200, JSON_CT, body]]) { |c| c.validate(:trading) }
      assert_parity([[200, JSON_CT, body]]) { |c| c.validate(:read) }
    end
  end

  def test_string_balance_entries
    ["abc", "balance", "hold_trade balance"].each do |balance|
      assert_parity([ok({ "X" => balance })], &:get_balances)
    end
  end

  def test_array_balance_entries
    [[["XXBT", { "balance" => "1" }]], ["x"], [["X", "abc"]], [["X", "balance"]],
     [[nil, { "balance" => "1" }]], [[]],
     [["XXBT", { "balance" => "1" }, "ignored"], ["XBT", { "balance" => "2" }]]].each do |balances|
      assert_parity([ok(balances)], &:get_balances)
    end
  end

  def test_array_order_entries
    raw = { "vol" => "1", "vol_exec" => "1", "cost" => "2", "price" => "0" }
    [[["O1", raw]], [[5, raw]], [[nil, raw]], ["x"], [["O1", "abc"]], [[]],
     [["O1", raw, "ignored"], ["O1", raw.merge("vol" => "2")]]].each do |orders|
      assert_parity([ok(orders)]) { |c| c.query_orders_info(txid: "O1") }
    end
  end

  def test_string_order_descriptions
    ["abc", "type", "ordertype price", "type ordertype price"].each do |descr|
      raw = { "descr" => descr, "vol" => "1", "vol_exec" => "1", "cost" => "2", "price" => "0" }
      assert_parity([ok({ "O1" => raw })]) { |c| c.query_orders_info(txid: "O1") }
    end
  end

  def test_hash_and_string_order_txids
    [{ "Z" => "first", "A" => "second" }, {}, "OX-1"].each do |txid|
      assert_parity([ok({ "txid" => txid })]) do |c|
        c.add_order(ordertype: "market", type: "buy", volume: "1", pair: "X")
      end
    end
  end

  def test_side_downcase_is_context_independent
    raw = { "descr" => { "type" => "ΑΣ" }, "vol" => "1", "vol_exec" => "1", "cost" => "2", "price" => "0" }
    assert_parity([ok({ "O1" => raw })]) { |c| c.query_orders_info(txid: "O1") }
  end

  def test_nil_parity_has_no_deprecation_warnings
    _, warnings = capture_io do
      assert_parity([ok({})]) { |c| c.add_order(ordertype: "market", type: "buy", volume: "1", pair: "X") }
    end
    refute_match(/DEPRECATED/, warnings)
  end

  def test_binary_maintenance_page_is_unreadable_like_legacy
    page = [200, { "content-type" => "text/html" }, "<html>\xFF\xFE maintenance</html>".b]
    assert_parity([page], &:get_balances)
    assert_parity([page]) { |c| c.query_orders_info(txid: "O1") }
    assert_parity([page]) { |c| c.add_order(ordertype: "market", type: "buy", volume: "1", pair: "X") }
    assert_parity([page]) { |c| c.validate(:trading) }
    assert_parity([ok({ "trades" => { "T1" => { "ordertxid" => "O1", "vol" => "1", "cost" => "1", "fee" => "0", "time" => 1 } }, "count" => 9 }), page]) do |c|
      c.closed_orders_from_trades(order_ids: %w[O1])
    end
  end

  def test_invalid_utf8_in_add_order_json
    ['{"error":[],"result":{"txid":["O1"],"descr":{"order":"buy X"}}}',
     '{"error":[],"result":{"txid":["OX"]}}'].each do |body|
      assert_parity([[200, JSON_CT, body.sub("X", "\xff")]]) do |c|
        c.add_order(ordertype: "market", type: "buy", volume: "1", pair: "X")
      end
    end
  end

  def direct_results(data)
    [Honeymaker::Clients::Kraken, Honeymaker::Native::KrakenClient].map do |klass|
      client = klass.new
      response = Honeymaker::Result::Success.new(data)
      client.stubs(:get_extended_balance).returns(response)
      client.stubs(:post_private).returns(response)
      client.stubs(:get_trades_history).returns(response)
      begin; yield(client); rescue StandardError => e; e; end
    end
  end

  def test_binary_error_text_through_client
    data = { "error" => ["EAPI:Invalid nonce \xff\xfe".b] }
    assert_same_ruby(*direct_results(data, &:get_balances))
  end

  def test_binary_and_invalid_normalizer_values
    ["\xff", "\xff".b].each do |suffix|
      data = { "error" => [], "result" => { "txid" => ["O" + suffix] } }
      assert_same_ruby(*direct_results(data) { |c| c.add_order(ordertype: "market", type: "buy", volume: "1", pair: "X") })
      ["balance" + suffix, { "balance" => "1" + suffix }].each do |balance|
        assert_same_ruby(*direct_results({ "result" => { "X" => balance } }, &:get_balances))
      end
      raw = { "vol" => "1", "vol_exec" => "1", "cost" => "2", "price" => "0" }
      [{ "descr" => "type" + suffix }, { "descr" => { "type" => "BUY" + suffix } },
       { "oflags" => "viqc," + suffix }].each do |over|
        assert_same_ruby(*direct_results({ "result" => { "O1" => raw.merge(over) } }) { |c| c.query_orders_info(txid: "O1") })
      end
    end
  end

  def test_invalid_string_keys_and_trade_side
    ["\xff", "\xff".b].each do |suffix|
      assert_same_ruby(*direct_results({ "result" => { "X" + suffix => { "balance" => "1" } } }, &:get_balances))
      raw = { "vol" => "1", "vol_exec" => "1", "cost" => "2", "price" => "0" }
      assert_same_ruby(*direct_results({ "result" => { "O" + suffix => raw } }) { |c| c.query_orders_info(txid: "O1") })
      trade = { "ordertxid" => "O1", "type" => "BUY" + suffix, "vol" => "1", "cost" => "2", "fee" => "0", "time" => 1 }
      assert_same_ruby(*direct_results({ "result" => { "trades" => { "T1" => trade }, "count" => 1 } }) do |c|
        c.closed_orders_from_trades(order_ids: ["O1"])
      end)
    end
  end

  def test_decimal_normalizers_under_gc_stress
    cases = [
      [{ "result" => { "XXBT" => { "balance" => "2", "hold_trade" => "0.5" } } }, ->(c) { c.get_balances }],
      [{ "result" => { "O1" => { "vol" => "1", "vol_exec" => "1", "cost" => "2", "price" => "2" } } },
       ->(c) { c.query_orders_info(txid: "O1") }],
      [{ "result" => { "trades" => { "T1" => { "ordertxid" => "O1", "type" => "buy", "ordertype" => "market",
          "vol" => "1", "cost" => "2", "fee" => "0.1", "time" => 1 } }, "count" => 1 } },
       ->(c) { c.closed_orders_from_trades(order_ids: ["O1"]) }]
    ]
    cases.each do |data, call|
      results = direct_results(data) do |client|
        GC.stress = true
        begin; call.call(client); ensure; GC.stress = false; end
      end
      assert_same_ruby(*results)
    end
  ensure
    GC.stress = false
  end

  def test_unexpected_native_verdict_raises_shape_error
    client = Honeymaker::Native::KrakenClient.new
    client.stubs(:native).returns(stub(finish: ["bogus"]))
    error = assert_raises(Honeymaker::Native::ShapeError) do
      client.send(:finish, "balances", Honeymaker::Result::Success.new({})) { |x| x }
    end
    assert_equal 'unexpected verdict "bogus"', error.message
  end

  def test_unauthenticated_private_call
    assert_parity([venue("EAPI:Invalid key")], key: nil, secret: nil, &:get_extended_balance)
  end

  def test_constants_and_surface
    assert_equal Honeymaker::Clients::Kraken.rate_limits, Honeymaker::Native::KrakenClient.rate_limits
    assert_equal Honeymaker::Clients::Kraken::URL, Honeymaker::Native::KrakenClient::URL
    legacy, native = Honeymaker::Clients::Kraken, Honeymaker::Native::KrakenClient
    assert_equal legacy.public_instance_methods(false).sort, native.public_instance_methods(false).sort
    legacy.public_instance_methods(false).each do |m|
      assert_equal legacy.instance_method(m).parameters, native.instance_method(m).parameters, "#{m} signature"
    end
    assert_respond_to native, :reset_nonce_state!
  end

  def test_rejected_arguments_raise_before_any_request
    [->(c) { c.add_order(ordertype: "market", type: "buy", volume: "1", pair: "X", oflags: nil) },
     ->(c) { c.add_order(ordertype: "market", type: "buy", volume: "1", pair: "X", oflags: "viqc") },
     ->(c) { c.get_tradable_asset_pairs(pairs: "XBTUSD") },
     ->(c) { c.get_asset_info(assets: 5) }].each do |call|
      lr, nr, lq, nq = run_both([ok({})], &call)
      assert_same_ruby(lr, nr)
      assert_equal [0, 0], [lq.size, nq.size], "no request may leave on a rejected argument"
    end
  end

  def test_argument_value_shapes_reach_the_wire_like_legacy
    assert_parity([ok({})]) { |c| c.query_orders_info(txid: %w[O1 O2]) }                 # repeated txid=
    assert_parity([ok({})]) { |c| c.add_order(ordertype: "market", type: "buy", volume: 1, pair: "X", oflags: [false]) }
    assert_parity([ok({})]) { |c| c.add_order(ordertype: "market", type: "buy", volume: "1", pair: "X", validate: false, userref: 0) }
    assert_parity([ok({})]) { |c| c.get_ohlc_data(pair: :XBTUSD, interval: 60.0, since: nil) }
  end

  def test_concurrent_private_calls_get_unique_increasing_nonces
    Honeymaker::Native::Ext::Kraken.fixed_nonce = nil
    d = VenueDouble.new([ok({})])
    c = Honeymaker::Native::KrakenClient.new(api_key: "k", api_secret: SECRET)
    c.instance_variable_set(:@connection, c.send(:build_client_connection, d.url))
    8.times.map { Thread.new { 10.times { assert c.get_extended_balance.success? } } }.each(&:join)
    nonces = d.requests.map { |r| r.body[/nonce=(\d+)/, 1].to_i }
    assert_equal 80, nonces.size
    assert_equal nonces.uniq.size, nonces.size, "unique per key"
  ensure
    d&.close
  end

  def test_api_key_with_trailing_newline
    assert_parity([ok({})], key: "test_key\n", &:get_extended_balance)
  end

  def test_native_uses_the_proxied_connection
    d = VenueDouble.new([ok({})])
    p = ProxyDouble.new(d.port)
    c = Honeymaker::Native::KrakenClient.new(api_key: "k", api_secret: SECRET, proxy: p.url)
    c.instance_variable_set(:@connection, c.send(:build_client_connection, d.url))
    assert c.get_extended_balance.success?
    assert_equal 1, p.lines.size, "request went through the proxy"
    assert_match %r{\APOST http://127\.0\.0\.1:#{d.port}/0/private/BalanceEx }, p.lines.first
  ensure
    p&.close
    d&.close
  end
end
