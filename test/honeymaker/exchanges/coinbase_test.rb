# frozen_string_literal: true

require "test_helper"

class Honeymaker::Exchanges::CoinbaseTest < Minitest::Test
  include FixtureHelper

  def setup
    @exchange = Honeymaker::Exchanges::Coinbase.new
  end

  def test_get_tickers_info_parses_response
    body = load_fixture("coinbase_products.json")
    stub_connection(body)

    result = @exchange.get_tickers_info

    assert result.success?
    # RENDER is blacklisted, so only BTC-USD should remain
    assert_equal 1, result.data.size
    ticker = result.data.first
    assert_equal "BTC-USD", ticker[:ticker]
    assert_equal "BTC", ticker[:base]
    assert_equal "USD", ticker[:quote]
    assert_equal "0.00000001", ticker[:minimum_base_size]
    assert_equal "1", ticker[:minimum_quote_size]
    assert_equal "3400", ticker[:maximum_base_size]
    assert_equal 8, ticker[:base_decimals]
    assert_equal 2, ticker[:quote_decimals]
    assert_equal 2, ticker[:price_decimals]
    assert ticker[:available]
  end

  def test_filters_blacklisted_assets
    body = load_fixture("coinbase_products.json")
    stub_connection(body)

    result = @exchange.get_tickers_info

    bases = result.data.map { |t| t[:base] }
    refute_includes bases, "RENDER"
  end

  private

  def stub_connection(body)
    response = stub(body: body)
    connection = stub
    connection.stubs(:get).returns(response)
    @exchange.instance_variable_set(:@connection, connection)
  end
end
