# frozen_string_literal: true

require "test_helper"

class Honeymaker::Exchanges::GeminiTest < Minitest::Test
  include FixtureHelper

  def setup
    @exchange = Honeymaker::Exchanges::Gemini.new
  end

  def test_get_tickers_info_parses_response
    symbols_body = load_fixture("gemini_symbols.json")
    detail_body = load_fixture("gemini_symbol_detail.json")

    symbols_response = stub(body: symbols_body)
    detail_response = stub(body: detail_body)
    connection = stub
    connection.stubs(:get).with("/v1/symbols").returns(symbols_response)
    connection.stubs(:get).with { |path| path.start_with?("/v1/symbols/details/") }.returns(detail_response)
    @exchange.instance_variable_set(:@connection, connection)

    result = @exchange.get_tickers_info

    assert result.success?
    assert_equal 2, result.data.size

    ticker = result.data.first
    assert_equal "BTCUSD", ticker[:ticker]
    assert_equal "BTC", ticker[:base]
    assert_equal "USD", ticker[:quote]
    assert_equal "0.00001", ticker[:minimum_base_size]
    assert_equal "0", ticker[:minimum_quote_size]
    assert_equal 8, ticker[:base_decimals]
    assert_equal 2, ticker[:quote_decimals]
    assert_equal 2, ticker[:price_decimals]
    assert ticker[:available]
  end

  def test_get_bid_ask_parses_response
    body = load_fixture("gemini_pubticker.json")
    stub_connection(body)

    result = @exchange.get_bid_ask("BTCUSD")

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
