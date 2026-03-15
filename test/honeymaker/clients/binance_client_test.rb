# frozen_string_literal: true

require "test_helper"

class Honeymaker::Clients::BinanceTest < Minitest::Test
  def setup
    @client = Honeymaker::Clients::Binance.new(api_key: "test_key", api_secret: "test_secret")
  end

  def test_url
    assert_equal "https://api.binance.com", Honeymaker::Clients::Binance::URL
  end

  def test_exchange_information
    stub_connection(:get, { "symbols" => [{ "symbol" => "BTCUSDT" }] })
    result = @client.exchange_information
    assert result.success?
    assert_equal "BTCUSDT", result.data["symbols"].first["symbol"]
  end

  def test_new_order
    stub_connection(:post, { "orderId" => 123, "status" => "FILLED" })
    result = @client.new_order(symbol: "BTCUSDT", side: "BUY", type: "MARKET", quantity: "0.001")
    assert result.success?
    assert_equal 123, result.data["orderId"]
  end

  def test_query_order
    stub_connection(:get, { "orderId" => 123, "status" => "FILLED" })
    result = @client.query_order(symbol: "BTCUSDT", order_id: 123)
    assert result.success?
  end

  def test_account_information
    stub_connection(:get, { "balances" => [{ "asset" => "BTC", "free" => "0.5" }] })
    result = @client.account_information
    assert result.success?
    assert_equal "BTC", result.data["balances"].first["asset"]
  end

  def test_cancel_order
    stub_connection(:delete, { "orderId" => 123, "status" => "CANCELED" })
    result = @client.cancel_order(symbol: "BTCUSDT", order_id: 123)
    assert result.success?
  end

  def test_handles_api_error
    connection = stub
    connection.stubs(:get).raises(Faraday::ServerError.new("500", { status: 500, body: "Server Error" }))
    @client.instance_variable_set(:@connection, connection)
    result = @client.exchange_information
    assert result.failure?
  end

  def test_headers_include_api_key
    headers = @client.send(:headers)
    assert_equal "test_key", headers[:"X-MBX-APIKEY"]
  end

  def test_headers_without_auth
    client = Honeymaker::Clients::Binance.new
    headers = client.send(:headers)
    refute headers.key?(:"X-MBX-APIKEY")
  end

  def test_sign_params
    sig = @client.send(:sign_params, { symbol: "BTCUSDT", timestamp: 1234567890 })
    assert sig.is_a?(String)
    assert_equal 64, sig.length
  end

  private

  def stub_connection(method, body)
    response = stub(body: body)
    connection = stub
    connection.stubs(method).returns(response)
    @client.instance_variable_set(:@connection, connection)
  end
end
