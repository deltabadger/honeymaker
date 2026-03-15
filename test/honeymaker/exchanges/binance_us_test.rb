# frozen_string_literal: true

require "test_helper"

class Honeymaker::Exchanges::BinanceUsTest < Minitest::Test
  include FixtureHelper

  def setup
    @exchange = Honeymaker::Exchanges::BinanceUs.new
  end

  def test_inherits_from_binance
    assert_kind_of Honeymaker::Exchanges::Binance, @exchange
  end

  def test_uses_binance_us_url
    assert_equal "https://api.binance.us", Honeymaker::Exchanges::BinanceUs::BASE_URL
  end

  def test_get_tickers_info_parses_response
    body = load_fixture("binance_exchange_info.json")
    stub_connection(body)

    result = @exchange.get_tickers_info

    assert result.success?
    ticker = result.data.first
    assert_equal "BTCUSDT", ticker[:ticker]
    assert_equal "BTC", ticker[:base]
  end

  private

  def stub_connection(body)
    response = stub(body: body)
    connection = stub
    connection.stubs(:get).with { |_, &block| block&.call(OpenStruct.new(params: {})); true }.returns(response)
    @exchange.instance_variable_set(:@connection, connection)
  end
end
