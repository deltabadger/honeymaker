# frozen_string_literal: true

require "test_helper"
require "digest"

class Honeymaker::Exchanges::MexcTest < Minitest::Test
  include FixtureHelper

  def setup
    @exchange = Honeymaker::Exchanges::Mexc.new
  end

  # H1. MEXC's exchangeInfo has never carried Binance's status encoding. The fixture this file
  # drives was a hand-edited clone of the Binance one ("TRADING"/"HALT", LOT_SIZE/PRICE_FILTER/
  # MIN_NOTIONAL filters) written from the same wrong assumption as the parser it tested, so both
  # agreed and both were wrong. Asserting the raw bytes is the only guard that survives an author
  # who believes the wrong thing twice; the digest also binds this file to deltabadger's copy, which
  # drives the same capture through the other implementation of this contract.
  def test_fixture_carries_mexcs_own_status_encoding
    body = load_fixture("mexc_exchange_info.json")

    assert_equal "1", body["symbols"].first["status"]
    refute body["symbols"].any? { |s| s["status"] == "TRADING" }
    refute body["symbols"].any? { |s| s["filters"].any? { |f| f["filterType"] == "LOT_SIZE" } }

    assert_equal "13a65c0c8ebde52fac4cdca9a5be9d9a18ba7b5438c496b1b30606cf52fd60d3",
                 Digest::SHA256.hexdigest(File.read(fixture_path("mexc_exchange_info.json")))
  end

  def test_get_tickers_info_parses_response
    body = load_fixture("mexc_exchange_info.json")
    stub_connection(body)

    result = @exchange.get_tickers_info

    assert result.success?
    assert_equal 2, result.data.size

    ticker = result.data.first
    assert_equal "METALUSDT", ticker[:ticker]
    assert_equal "METAL", ticker[:base]
    assert_equal "USDT", ticker[:quote]
    assert ticker[:available]
    assert ticker[:trading_enabled]
  end

  # H2. status is "1" for every MEXC symbol, including the 103 the venue will not accept a spot
  # order for. The status check alone re-enables all of them; isSpotTradingAllowed is what keeps
  # them out of the picker.
  def test_a_symbol_mexc_does_not_allow_for_spot_is_not_trading_enabled
    body = load_fixture("mexc_exchange_info.json")
    stub_connection(body)

    result = @exchange.get_tickers_info

    disallowed = result.data.find { |t| t[:ticker] == "PALMAIUSDT" }
    assert_equal "1", body["symbols"].last["status"]
    assert disallowed[:available]        # still listed
    refute disallowed[:trading_enabled]  # but not spot-tradable
  end

  # H5. Real MEXC sends only PERCENT_PRICE_BY_SIDE, so the precision fallback is the ONLY path —
  # there is no filter-bearing symbol to contrast it against.
  def test_falls_back_to_precision_fields_when_no_size_filters
    body = load_fixture("mexc_exchange_info.json")
    stub_connection(body)

    result = @exchange.get_tickers_info

    metal = result.data.find { |t| t[:ticker] == "METALUSDT" }
    assert_equal 2, metal[:base_decimals]   # baseAssetPrecision
    assert_equal 5, metal[:quote_decimals]  # quoteAssetPrecision
    assert_equal 5, metal[:price_decimals]  # quotePrecision
    assert_nil metal[:minimum_base_size]
    assert_nil metal[:minimum_quote_size]
  end

  def test_get_bid_ask_parses_response
    body = load_fixture("mexc_book_ticker.json")
    stub_connection(body)

    result = @exchange.get_bid_ask("BTCUSDT")

    assert result.success?
    assert_equal BigDecimal("67123.45"), result.data[:bid]
    assert_equal BigDecimal("67125.67"), result.data[:ask]
  end

  private

  def stub_connection(body)
    response = stub(body: body)
    connection = stub
    connection.stubs(:get).returns(response)
    @exchange.instance_variable_set(:@connection, connection)
  end
end
