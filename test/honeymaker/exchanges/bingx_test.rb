# frozen_string_literal: true

require "test_helper"

class Honeymaker::Exchanges::BingXTest < Minitest::Test
  include FixtureHelper

  def setup
    @exchange = Honeymaker::Exchanges::BingX.new
  end

  def test_get_tickers_info_parses_response
    body = load_fixture("bingx_symbols.json")
    stub_connection(body)

    result = @exchange.get_tickers_info

    assert result.success?
    # "INVALID" has no dash so it's skipped
    assert_equal 1, result.data.size

    ticker = result.data.first
    assert_equal "BTC-USDT", ticker[:ticker]
    assert_equal "BTC", ticker[:base]
    assert_equal "USDT", ticker[:quote]
    assert_equal "0.00001", ticker[:minimum_base_size]
    assert_equal "1", ticker[:minimum_quote_size]
    assert_equal "500", ticker[:maximum_base_size]
    assert_equal 5, ticker[:base_decimals]
    assert_equal 2, ticker[:quote_decimals]
    assert_equal 2, ticker[:price_decimals]
    assert ticker[:available]
  end

  def test_skips_symbols_without_dash
    body = load_fixture("bingx_symbols.json")
    stub_connection(body)

    result = @exchange.get_tickers_info

    tickers = result.data.map { |t| t[:ticker] }
    refute_includes tickers, "INVALID"
  end

  def test_get_bid_ask_parses_response
    body = load_fixture("bingx_ticker.json")
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
