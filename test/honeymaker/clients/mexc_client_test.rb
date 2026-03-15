# frozen_string_literal: true

require "test_helper"

class Honeymaker::Clients::MexcTest < Minitest::Test
  def setup
    @client = Honeymaker::Clients::Mexc.new(api_key: "test_key", api_secret: "test_secret")
  end

  def test_url
    assert_equal "https://api.mexc.com", Honeymaker::Clients::Mexc::URL
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

  def test_withdraw
    stub_connection(:post, { "id" => "w1" })
    result = @client.withdraw(coin: "BTC", address: "addr", amount: "0.1")
    assert result.success?
  end

  def test_headers_include_api_key
    headers = @client.send(:headers)
    assert_equal "test_key", headers[:"X-MEXC-APIKEY"]
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
