# frozen_string_literal: true

require "test_helper"

class Honeymaker::Exchanges::KrakenTest < Minitest::Test
  include FixtureHelper

  def setup
    @exchange = Honeymaker::Exchanges::Kraken.new
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
  end

  def test_get_tickers_info_skips_pairs_without_wsname
    body = load_fixture("kraken_asset_pairs.json")
    body["result"]["XBTUSDT"]["wsname"] = nil
    stub_request(body)

    result = @exchange.get_tickers_info

    assert result.success?
    assert_empty result.data
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

  private

  def stub_request(body)
    response = stub(body: body)
    connection = stub
    connection.stubs(:get).returns(response)
    @exchange.instance_variable_set(:@connection, connection)
  end
end
