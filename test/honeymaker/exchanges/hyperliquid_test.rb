# frozen_string_literal: true

require "test_helper"

class Honeymaker::Exchanges::HyperliquidTest < Minitest::Test
  include FixtureHelper

  def setup
    @exchange = Honeymaker::Exchanges::Hyperliquid.new
  end

  def test_get_tickers_info_parses_response
    body = load_fixture("hyperliquid_spot_meta.json")
    stub_connection(body)

    result = @exchange.get_tickers_info

    assert result.success?
    assert_equal 1, result.data.size

    ticker = result.data.first
    assert_equal "PURR/USDC", ticker[:ticker]
    assert_equal "PURR", ticker[:base]
    assert_equal "USDC", ticker[:quote]
    assert_nil ticker[:minimum_base_size]
    assert_nil ticker[:minimum_quote_size]
    assert_equal 2, ticker[:base_decimals]
    assert_equal 2, ticker[:quote_decimals]
    assert_equal 5, ticker[:price_decimals]
    assert ticker[:available]
  end

  def test_skips_pairs_with_missing_tokens
    body = load_fixture("hyperliquid_spot_meta.json")
    body["universe"] << { "name" => "MISSING/PAIR", "tokens" => [99, 100] }
    stub_connection(body)

    result = @exchange.get_tickers_info

    assert result.success?
    assert_equal 1, result.data.size
  end

  def test_get_bid_ask_parses_response
    body = load_fixture("hyperliquid_all_mids.json")
    stub_connection(body)

    result = @exchange.get_bid_ask("BTC/USDC")

    assert result.success?
    assert_equal BigDecimal("67124.56"), result.data[:bid]
    assert_equal BigDecimal("67124.56"), result.data[:ask]
  end

  private

  def stub_connection(body)
    response = stub(body: body)
    connection = stub
    connection.stubs(:post).with { |_, &block| block&.call(OpenStruct.new(body: nil)); true }.returns(response)
    @exchange.instance_variable_set(:@connection, connection)
  end
end
