# frozen_string_literal: true

require "test_helper"

class Honeymaker::Exchanges::BitrueTest < Minitest::Test
  include FixtureHelper

  def setup
    @exchange = Honeymaker::Exchanges::Bitrue.new
  end

  def test_get_tickers_info_parses_response
    body = load_fixture("bitrue_exchange_info.json")
    stub_connection(body)

    result = @exchange.get_tickers_info

    assert result.success?
    assert_equal 2, result.data.size

    ticker = result.data.first
    assert_equal "BTCUSDT", ticker[:ticker]
    assert_equal "BTC", ticker[:base]
    assert_equal "USDT", ticker[:quote]
    assert_equal "0.00001", ticker[:minimum_base_size]
    assert_equal "5", ticker[:minimum_quote_size]
    assert_equal "9000", ticker[:maximum_base_size]
    assert_equal 5, ticker[:base_decimals]
    assert_equal 2, ticker[:quote_decimals]
    assert_equal 2, ticker[:price_decimals]
    assert ticker[:available]
  end

  def test_falls_back_to_precision_fields_when_no_filters
    body = load_fixture("bitrue_exchange_info.json")
    stub_connection(body)

    result = @exchange.get_tickers_info

    eth = result.data.find { |t| t[:ticker] == "ETHUSDT" }
    assert_equal 6, eth[:base_decimals]
    assert_equal 2, eth[:price_decimals]
  end

  def test_get_bid_ask_parses_response
    body = load_fixture("bitrue_book_ticker.json")
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
