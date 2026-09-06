# frozen_string_literal: true

require "test_helper"

class Honeymaker::Exchanges::KrakenTest < Minitest::Test
  include FixtureHelper

  def setup
    @exchange = Honeymaker::Exchanges::Kraken.new
  end

  # Tokenized equities (xStocks) live behind aclass_base and are invisible to a bare AssetPairs call.
  # aclass_base=all returns currency + tokenized in one request; the two sets are disjoint.
  def test_get_tickers_info_requests_every_asset_class
    response = stub(body: load_fixture("kraken_asset_pairs.json"))
    connection = stub
    connection.expects(:get).with("/0/public/AssetPairs", { aclass_base: "all" }).returns(response)
    @exchange.instance_variable_set(:@connection, connection)

    assert @exchange.get_tickers_info.success?
  end

  # Kraken returns every tokenized pair TWICE - once under an SPV key, once under the x key - with
  # one shared wsname and altname. Only tokenized pairs are double-keyed; currency pairs never are.
  # Mapping the raw response would ingest each of them twice.
  def test_get_tickers_info_deduplicates_the_spv_alias
    body = load_fixture("kraken_asset_pairs.json")
    stub_request(body)

    result = @exchange.get_tickers_info

    nvda = result.data.select { |t| t[:base] == "NVDAx" }
    assert_equal 1, nvda.size, "NVDAxUSD and NVDASPVUSD are one pair"
    assert_equal "NVDAxUSD", nvda.first[:ticker]
  end

  # Listed, so a holding can be resolved and valued; not tradable, because AddOrder needs an
  # asset_class parameter this client does not send, and Kraken closes the tokenized order books to
  # EEA clients over the API regardless.
  def test_tokenized_pairs_are_listed_but_not_trading_enabled
    body = load_fixture("kraken_asset_pairs.json")
    stub_request(body)

    nvda = @exchange.get_tickers_info.data.find { |t| t[:base] == "NVDAx" }

    assert_equal "online", body["result"]["NVDAxUSD"]["status"]
    assert nvda[:available], "listed, so balances resolve"
    refute nvda[:trading_enabled], "we cannot place these orders"
  end

  def test_get_tickers_info_parses_response
    body = load_fixture("kraken_asset_pairs.json")
    stub_request(body)

    result = @exchange.get_tickers_info

    assert result.success?
    ticker = result.data.first
    assert_equal "XBTUSDT", ticker[:ticker]
    assert_equal "XBT", ticker[:base]
    assert_equal "USDT", ticker[:quote]
    assert_equal "0.00010000", ticker[:minimum_base_size]
    assert_equal "5", ticker[:minimum_quote_size]
    assert_equal 8, ticker[:base_decimals]
    assert_equal 5, ticker[:quote_decimals]
    assert_equal 1, ticker[:price_decimals]
    assert ticker[:available]
    assert ticker[:trading_enabled] # fixture has no status -> defaults to true
  end

  def test_get_tickers_info_disables_non_online_status
    body = load_fixture("kraken_asset_pairs.json")
    body["result"]["XBTUSDT"]["status"] = "cancel_only"
    stub_request(body)

    result = @exchange.get_tickers_info

    ticker = result.data.first
    assert ticker[:available]        # still listed
    refute ticker[:trading_enabled]  # but not trading
  end

  def test_get_tickers_info_enables_online_status
    body = load_fixture("kraken_asset_pairs.json")
    body["result"]["XBTUSDT"]["status"] = "online"
    stub_request(body)

    result = @exchange.get_tickers_info

    assert result.data.first[:trading_enabled]
  end

  def test_get_tickers_info_defaults_trading_enabled_when_status_absent
    body = load_fixture("kraken_asset_pairs.json") # no status key
    stub_request(body)

    result = @exchange.get_tickers_info

    assert result.data.first[:trading_enabled]
  end

  def test_get_tickers_info_skips_pairs_without_wsname
    body = load_fixture("kraken_asset_pairs.json")
    body["result"]["XBTUSDT"]["wsname"] = nil
    stub_request(body)

    result = @exchange.get_tickers_info

    assert result.success?
    # Asserts the wsname-less pair is dropped, not that the whole response is - the fixture now
    # carries a tokenized pair too.
    refute result.data.any? { |t| t[:ticker] == "XBTUSDT" }
  end

  def test_get_tickers_info_uses_real_costmin
    body = load_fixture("kraken_asset_pairs.json")
    stub_request(body)

    result = @exchange.get_tickers_info

    ticker = result.data.first
    # USDT is in REAL_COSTMIN with value 5
    assert_equal "5", ticker[:minimum_quote_size]
  end

  def test_get_tickers_info_handles_api_error
    body = { "error" => ["EGeneral:Internal error"], "result" => {} }
    stub_request(body)

    result = @exchange.get_tickers_info

    assert result.failure?
    assert_includes result.errors, "EGeneral:Internal error"
  end

  def test_get_bid_ask_parses_response
    body = load_fixture("kraken_ticker.json")
    stub_request(body)

    result = @exchange.get_bid_ask("XBTUSDT")

    assert result.success?
    assert_equal BigDecimal("67123.45"), result.data[:bid]
    assert_equal BigDecimal("67125.67"), result.data[:ask]
  end

  def test_get_bid_ask_handles_api_error
    body = { "error" => ["EGeneral:Internal error"], "result" => {} }
    stub_request(body)

    result = @exchange.get_bid_ask("XBTUSDT")

    assert result.failure?
  end

  def test_classify_error_regional_restriction
    result = @exchange.classify_error("EAccount:Invalid permissions:XAUT trading restricted for DK.")
    assert_equal({ code: :regional_restriction, asset: "XAUT", country: "DK" }, result)
  end

  def test_classify_error_invalid_nonce
    assert_equal({ code: :transient_nonce }, @exchange.classify_error("EAPI:Invalid nonce"))
  end

  def test_classify_error_internal_error_is_transient_unavailable
    assert_equal({ code: :transient_unavailable }, @exchange.classify_error("EGeneral:Internal error"))
  end

  def test_classify_error_service_codes_are_transient_unavailable
    assert_equal({ code: :transient_unavailable }, @exchange.classify_error("EService:Unavailable"))
    assert_equal({ code: :transient_unavailable }, @exchange.classify_error("EService:Busy"))
    assert_equal({ code: :transient_unavailable }, @exchange.classify_error("EService:Deadline elapsed"))
  end

  def test_classify_error_returns_nil_for_unknown_message
    assert_nil @exchange.classify_error("EOrder:Unknown order")
  end

  def test_classify_error_returns_nil_for_nil_message
    assert_nil @exchange.classify_error(nil)
  end

  private

  def stub_request(body)
    response = stub(body: body)
    connection = stub
    connection.stubs(:get).returns(response)
    @exchange.instance_variable_set(:@connection, connection)
  end
end
