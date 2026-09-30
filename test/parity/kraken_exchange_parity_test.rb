# frozen_string_literal: true

require "test_helper"
require "support/parity_helper"

class KrakenExchangeParityTest < Minitest::Test
  include ParityHelper
  include FixtureHelper

  JSON_CT = { "content-type" => "application/json" }.freeze

  def assert_parity(reply)
    d = VenueDouble.new([reply])
    results = [Honeymaker::Exchanges::Kraken, Honeymaker::Native::KrakenExchange].map do |k|
      d.reset!([reply])
      e = k.new
      e.instance_variable_set(:@connection, e.send(:build_connection, d.url))
      r = begin; yield(e); rescue StandardError => x; x; end
      [r, d.requests.map { |q| [q.method, q.target] }]
    end
    assert_same_ruby(results[0][0], results[1][0])
    assert_equal results[0][1], results[1][1]
  ensure
    d&.close
  end

  def test_tickers_info_from_the_real_fixture
    assert_parity([200, JSON_CT, File.read(fixture_path("kraken_asset_pairs.json"))], &:get_tickers_info)
  end

  def test_tickers_info_edges
    pairs = {
      "XXBTZUSD" => { "altname" => "XBTUSD", "wsname" => "XBT/USD", "ordermin" => "0.0001", "costmin" => "0.5",
                      "lot_decimals" => 8, "cost_decimals" => 5, "pair_decimals" => 1, "status" => "online" },
      "NVDASPVUSD" => { "altname" => "NVDAxUSD", "wsname" => "NVDAx/USD", "aclass_base" => "tokenized_asset", "ordermin" => "0.1" },
      "NVDAxUSD" => { "altname" => "NVDAxUSD", "wsname" => "NVDAx/USD", "aclass_base" => "tokenized_asset" },
      "NOWS" => { "altname" => "NOWS", "wsname" => "" },
      "WEIRD" => { "altname" => "W", "wsname" => "ABC", "costmin" => 7.5, "status" => "cancel_only" },
      "XF" => { "altname" => "XF", "wsname" => "ETH/XBT", "costmin" => "1" }
    }
    [[200, JSON_CT, { "error" => [], "result" => pairs }.to_json],
     [200, JSON_CT, '{"error":["EGeneral:Temporary lockout"]}'],
     [500, JSON_CT, "{}"]].each { |reply| assert_parity(reply, &:get_tickers_info) }
  end

  def test_one_malformed_row_fails_the_whole_catalogue_like_legacy
    replies = [false, 1, { "x" => 1 }].map do |bad|
      pairs = { "XXBTZUSD" => { "altname" => "XBTUSD", "wsname" => "XBT/USD", "status" => "online" },
                "BAD" => { "altname" => "BAD", "wsname" => bad } }
      [200, JSON_CT, { "error" => [], "result" => pairs }.to_json]
    end
    # Non-object bodies too: Failure on both, messages differ (spec §5.1).
    replies += [[200, { "content-type" => "text/html" }, "x"], [200, JSON_CT, "null"],
                [200, { "content-type" => "text/html" }, "\xFF\xFE".b]]
    replies.each do |reply|
      bad = reply[2][0, 40]
      d = VenueDouble.new([reply])
      rs = [Honeymaker::Exchanges::Kraken, Honeymaker::Native::KrakenExchange].map do |k|
        d.reset!([reply])
        e = k.new
        e.instance_variable_set(:@connection, e.send(:build_connection, d.url))
        e.get_tickers_info
      end
      assert rs.all?(&:failure?), "wsname=#{bad.inspect} must fail the catalogue on both"
      assert_nullable_equal rs[0].data, rs[1].data
    ensure
      d&.close
    end
  end

  def test_bid_ask_and_price
    t = { "error" => [], "result" => { "XXBTZUSD" => { "a" => ["50000.10", "1", "1.000"], "b" => ["49999.90", "2", "2.000"] } } }.to_json
    assert_parity([200, JSON_CT, t]) { |e| e.get_bid_ask("XBTUSD") }
    assert_parity([200, JSON_CT, t]) { |e| e.get_price("XBTUSD") }
    assert_parity([200, JSON_CT, '{"error":["EQuery:Unknown asset pair"]}']) { |e| e.get_bid_ask("NOPE") }
    assert_parity([200, JSON_CT, '{"error":[],"result":{"X":{"a":["NaN"],"b":["-0"]}}}']) { |e| e.get_bid_ask("X") }
    assert_parity([200, JSON_CT, '{"error":[],"result":{"X":{"a":[50001],"b":[50000]}}}']) { |e| e.get_bid_ask("X") }
    assert_parity([200, JSON_CT, '{"error":[],"result":{"X":{"a":[1.5],"b":[1.25]}}}']) { |e| e.get_bid_ask("X") }
  end

  def test_classify_error_corpus
    ["EAccount:Invalid permissions:NVDAx trading restricted for DE.",
     "EAccount:Invalid permissions:XBT trading restricted for US",
     "EAccount:Invalid permissions:XBT trading restricted for \u00dc.",
     "prefix EAPI:Invalid nonce suffix", "EGeneral:Internal error", "EService:Unavailable",
     "EService:Busy", "EService:Deadline elapsed", "EOrder:Insufficient funds", "", nil].each do |msg|
      assert_nullable_equal Honeymaker::Exchanges::Kraken.new.classify_error(msg),
                   Honeymaker::Native::KrakenExchange.new.classify_error(msg), msg.inspect
    end
  end

  def test_non_object_catalogue_body_is_a_failure_on_both
    [[200, { "content-type" => "text/html" }, "x"], [200, JSON_CT, "null"]].each do |reply|
      d = VenueDouble.new([reply])
      rs = [Honeymaker::Exchanges::Kraken, Honeymaker::Native::KrakenExchange].map do |k|
        d.reset!([reply])
        e = k.new
        e.instance_variable_set(:@connection, e.send(:build_connection, d.url))
        e.get_tickers_info
      end
      assert rs.all?(&:failure?)
      assert_nullable_equal rs[0].data, rs[1].data
    ensure
      d&.close
    end
  end

  def assert_nullable_equal(expected, actual, msg = nil)
    expected.nil? ? assert_nil(actual, msg) : assert_equal(expected, actual, msg)
  end

  def test_catalogue_ruby_shapes
    [[], {}, [["X", { "wsname" => "X/USD", "altname" => "XUSD" }]],
     { "X" => "no fields" },
     { "X" => { "wsname" => {} } },
     { "X" => { "wsname" => [] } }].each do |pairs|
      assert_parity([200, JSON_CT, { "error" => [], "result" => pairs }.to_json], &:get_tickers_info)
    end
    pairs = ["/", "//", "X/", "X//", "/USD", "X//USD", "X/USD/"].to_h do |ws|
      [ws, { "wsname" => ws, "altname" => ws, "costmin" => false, "status" => nil }]
    end
    assert_parity([200, JSON_CT, { "error" => [false, nil], "result" => pairs }.to_json], &:get_tickers_info)
  end

  def test_bid_ask_ruby_indexing_and_decimal_errors
    [{ "a" => "23", "b" => "12" }, { "a" => 3, "b" => 2 },
     { "a" => ["invalid"], "b" => ["1"] }, "ab"].each do |row|
      [{ "X" => row }, [["X", row]]].each do |result|
        assert_parity([200, JSON_CT, { "error" => [], "result" => result }.to_json]) { |e| e.get_bid_ask("X") }
      end
    end
  end

  def test_catalogue_under_gc_stress
    body = File.read(fixture_path("kraken_asset_pairs.json"))
    GC.stress = true
    assert_parity([200, JSON_CT, body], &:get_tickers_info)
  ensure
    GC.stress = false
  end
end
