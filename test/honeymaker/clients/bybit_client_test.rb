# frozen_string_literal: true

require "test_helper"

class Honeymaker::Clients::BybitTest < Minitest::Test
  def setup
    @client = Honeymaker::Clients::Bybit.new(api_key: "test_key", api_secret: "test_secret")
  end

  def test_url
    assert_equal "https://api.bybit.com", Honeymaker::Clients::Bybit::URL
  end

  def test_instruments_info
    stub_connection(:get, { "result" => { "list" => [{ "symbol" => "BTCUSDT" }] } })
    result = @client.instruments_info(category: "spot")
    assert result.success?
  end

  def test_tickers
    stub_connection(:get, { "result" => { "list" => [{ "lastPrice" => "50000" }] } })
    result = @client.tickers(category: "spot", symbol: "BTCUSDT")
    assert result.success?
  end

  def test_wallet_balance
    stub_connection(:get, { "result" => { "list" => [{ "coin" => [{ "coin" => "BTC" }] }] } })
    result = @client.wallet_balance(account_type: "UNIFIED")
    assert result.success?
  end

  def test_create_order
    stub_connection(:post, { "result" => { "orderId" => "123" } })
    result = @client.create_order(category: "spot", symbol: "BTCUSDT", side: "Buy", order_type: "Market", qty: "0.001")
    assert result.success?
    assert_equal "123", result.data["result"]["orderId"]
  end

  def test_get_order
    stub_connection(:get, { "result" => { "list" => [{ "orderId" => "123" }] } })
    result = @client.get_order(category: "spot", order_id: "123")
    assert result.success?
  end

  def test_cancel_order
    stub_connection(:post, { "result" => { "orderId" => "123" } })
    result = @client.cancel_order(category: "spot", symbol: "BTCUSDT", order_id: "123")
    assert result.success?
  end

  def test_kline
    stub_connection(:get, { "result" => { "list" => [] } })
    result = @client.kline(category: "spot", symbol: "BTCUSDT", interval: "60")
    assert result.success?
  end

  def test_withdraw
    stub_connection(:post, { "result" => { "id" => "w1" } })
    result = @client.withdraw(coin: "BTC", chain: "BTC", address: "addr", amount: "0.1")
    assert result.success?
  end

  def test_signed_headers_include_api_key
    headers = @client.send(:signed_headers, "GET", { foo: "bar" })
    assert_equal "test_key", headers[:"X-BAPI-API-KEY"]
    assert headers.key?(:"X-BAPI-SIGN")
    assert headers.key?(:"X-BAPI-TIMESTAMP")
  end

  def test_unauthenticated_client
    client = Honeymaker::Clients::Bybit.new
    headers = client.send(:signed_headers, "GET", {})
    refute headers.key?(:"X-BAPI-SIGN")
  end

  private

  def stub_connection(method, body)
    response = stub(body: body)
    connection = stub
    connection.stubs(method).returns(response)
    @client.instance_variable_set(:@connection, connection)
  end
end
