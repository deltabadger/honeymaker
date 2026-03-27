# frozen_string_literal: true

require "test_helper"

class Honeymaker::Exchanges::KucoinTest < Minitest::Test
  include FixtureHelper

  def setup
    @exchange = Honeymaker::Exchanges::Kucoin.new
  end

  def test_get_tickers_info_parses_response
    body = load_fixture("kucoin_symbols.json")
    stub_connection(body)

    result = @exchange.get_tickers_info

    assert result.success?
    assert_equal 1, result.data.size

    ticker = result.data.first
    assert_equal "BTC-USDT", ticker[:ticker]
    assert_equal "BTC", ticker[:base]
    assert_equal "USDT", ticker[:quote]
    assert_equal "0.00001", ticker[:minimum_base_size]
    assert_equal "0.1", ticker[:minimum_quote_size]
    assert_equal "10000000000", ticker[:maximum_base_size]
    assert_equal "99999999", ticker[:maximum_quote_size]
    assert_equal 8, ticker[:base_decimals]
    assert_equal 6, ticker[:quote_decimals]
    assert_equal 1, ticker[:price_decimals]
    assert ticker[:available]
  end

  def test_get_bid_ask_parses_response
    body = load_fixture("kucoin_orderbook_level1.json")
    stub_connection(body)

    result = @exchange.get_bid_ask("BTC-USDT")

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
