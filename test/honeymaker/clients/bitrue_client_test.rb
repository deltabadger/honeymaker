# frozen_string_literal: true

require "test_helper"

class Honeymaker::Clients::BitrueTest < Minitest::Test
  def setup
    @client = Honeymaker::Clients::Bitrue.new(api_key: "test_key", api_secret: "test_secret")
  end

  def test_url
    assert_equal "https://openapi.bitrue.com", Honeymaker::Clients::Bitrue::URL
  end

  def test_exchange_information
    stub_connection(:get, { "symbols" => [{ "symbol" => "BTCUSDT" }] })
    result = @client.exchange_information
    assert result.success?
  end

  def test_symbol_price_ticker
    stub_connection(:get, { "symbol" => "BTCUSDT", "price" => "50000" })
    result = @client.symbol_price_ticker(symbol: "BTCUSDT")
    assert result.success?
  end

  def test_account_information
    stub_connection(:get, { "balances" => [{ "asset" => "BTC" }] })
    result = @client.account_information
    assert result.success?
  end

  def test_new_order
    stub_connection(:post, { "orderId" => "123" })
    result = @client.new_order(symbol: "BTCUSDT", side: "BUY", type: "MARKET", quantity: "0.001")
    assert result.success?
  end

  def test_query_order
    stub_connection(:get, { "orderId" => "123", "status" => "FILLED" })
    result = @client.query_order(symbol: "BTCUSDT", order_id: "123")
    assert result.success?
  end

  def test_cancel_order
    stub_connection(:delete, { "orderId" => "123" })
    result = @client.cancel_order(symbol: "BTCUSDT", order_id: "123")
    assert result.success?
  end

  def test_account_trade_list
    stub_connection(:get, [{ "symbol" => "BTCUSDT", "id" => 1 }])
    result = @client.account_trade_list(symbol: "BTCUSDT")
    assert result.success?
  end

  def test_headers_include_api_key
    headers = @client.send(:auth_headers)
    assert_equal "test_key", headers[:"X-MBX-APIKEY"]
  end

  private

  def stub_connection(method, body)
    response = stub(body: body)
    connection = stub
    connection.stubs(method).returns(response)
    @client.instance_variable_set(:@connection, connection)
  end
end
