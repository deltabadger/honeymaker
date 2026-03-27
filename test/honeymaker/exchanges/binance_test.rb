# frozen_string_literal: true

require "test_helper"

class Honeymaker::Exchanges::BinanceTest < Minitest::Test
  include FixtureHelper

  def setup
    @exchange = Honeymaker::Exchanges::Binance.new
  end

  def test_get_tickers_info_parses_response
    body = load_fixture("binance_exchange_info.json")
    stub_connection(body)

    result = @exchange.get_tickers_info

    assert result.success?
    ticker = result.data.first
    assert_equal "BTCUSDT", ticker[:ticker]
    assert_equal "BTC", ticker[:base]
    assert_equal "USDT", ticker[:quote]
    assert_equal "0.00000100", ticker[:minimum_base_size]
    assert_equal "5.00000000", ticker[:minimum_quote_size]
    assert_equal 6, ticker[:base_decimals]
    assert_equal 8, ticker[:quote_decimals]
    assert_equal 2, ticker[:price_decimals]
    assert ticker[:available]
  end

  def test_get_tickers_info_handles_api_error
    connection = stub
    connection.stubs(:get).raises(Faraday::ServerError.new("500", { status: 500, body: "Internal Server Error" }))
    @exchange.instance_variable_set(:@connection, connection)

    result = @exchange.get_tickers_info

    assert result.failure?
  end

  def test_get_bid_ask_parses_response
    body = load_fixture("binance_book_ticker.json")
    stub_connection(body)

    result = @exchange.get_bid_ask("BTCUSDT")

    assert result.success?
    assert_equal BigDecimal("67123.45"), result.data[:bid]
    assert_equal BigDecimal("67125.67"), result.data[:ask]
  end

  def test_get_bid_ask_handles_api_error
    connection = stub
    connection.stubs(:get).raises(Faraday::ServerError.new("500", { status: 500, body: "Internal Server Error" }))
    @exchange.instance_variable_set(:@connection, connection)

    result = @exchange.get_bid_ask("BTCUSDT")

    assert result.failure?
  end

  private

  def stub_connection(body)
    response = stub(body: body)
    connection = stub
    connection.stubs(:get).with { |path, &block| block&.call(OpenStruct.new(params: {})); true }.returns(response)
    @exchange.instance_variable_set(:@connection, connection)
  end
end
