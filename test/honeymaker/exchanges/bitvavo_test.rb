# frozen_string_literal: true

require "test_helper"

class Honeymaker::Exchanges::BitvavoTest < Minitest::Test
  include FixtureHelper

  def setup
    @exchange = Honeymaker::Exchanges::Bitvavo.new
  end

  def test_get_tickers_info_parses_response
    body = load_fixture("bitvavo_markets.json")
    stub_connection(body)

    result = @exchange.get_tickers_info

    assert result.success?
    assert_equal 2, result.data.size

    ticker = result.data.first
    assert_equal "BTC-EUR", ticker[:ticker]
    assert_equal "BTC", ticker[:base]
    assert_equal "EUR", ticker[:quote]
    assert_equal "0.00001", ticker[:minimum_base_size]
    assert_equal "5", ticker[:minimum_quote_size]
    assert_nil ticker[:maximum_base_size]
    assert_equal 5, ticker[:base_decimals]
    assert_equal 5, ticker[:quote_decimals]
    assert_equal 5, ticker[:price_decimals]
    assert ticker[:available]
  end

  def test_halted_market_not_available
    body = load_fixture("bitvavo_markets.json")
    stub_connection(body)

    result = @exchange.get_tickers_info

    eth = result.data.find { |t| t[:ticker] == "ETH-EUR" }
    refute eth[:available]
  end

  private

  def stub_connection(body)
    response = stub(body: body)
    connection = stub
    connection.stubs(:get).returns(response)
    @exchange.instance_variable_set(:@connection, connection)
  end
end
