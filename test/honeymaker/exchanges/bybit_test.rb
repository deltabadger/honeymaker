# frozen_string_literal: true

require "test_helper"

class Honeymaker::Exchanges::BybitTest < Minitest::Test
  include FixtureHelper

  def setup
    @exchange = Honeymaker::Exchanges::Bybit.new
  end

  def test_get_tickers_info_parses_response
    body = load_fixture("bybit_instruments.json")
    stub_connection(body)

    result = @exchange.get_tickers_info

    assert result.success?
    assert_equal 1, result.data.size

    ticker = result.data.first
    assert_equal "BTCUSDT", ticker[:ticker]
    assert_equal "BTC", ticker[:base]
    assert_equal "USDT", ticker[:quote]
    assert_equal "0.000048", ticker[:minimum_base_size]
    assert_equal "1", ticker[:minimum_quote_size]
    assert_equal "71.73956243", ticker[:maximum_base_size]
    assert_equal "4000000", ticker[:maximum_quote_size]
    assert_equal 6, ticker[:base_decimals]
    assert_equal 8, ticker[:quote_decimals]
    assert_equal 2, ticker[:price_decimals]
    assert ticker[:available]
  end

  def test_get_bid_ask_parses_response
    body = load_fixture("bybit_tickers.json")
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
    connection.stubs(:get).with { |_, &block| block&.call(OpenStruct.new(params: {})); true }.returns(response)
    @exchange.instance_variable_set(:@connection, connection)
  end
end
