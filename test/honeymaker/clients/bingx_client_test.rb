# frozen_string_literal: true

require "test_helper"

class Honeymaker::Clients::BingXTest < Minitest::Test
  def setup
    @client = Honeymaker::Clients::BingX.new(api_key: "test_key", api_secret: "test_secret")
  end

  def test_url
    assert_equal "https://open-api.bingx.com", Honeymaker::Clients::BingX::URL
  end

  def test_get_symbols
    stub_connection(:get, { "data" => { "symbols" => [{ "symbol" => "BTC-USDT" }] } })
    result = @client.get_symbols
    assert result.success?
  end

  def test_get_ticker
    stub_connection(:get, { "data" => [{ "symbol" => "BTC-USDT" }] })
    result = @client.get_ticker(symbol: "BTC-USDT")
    assert result.success?
  end

  def test_get_balances
    stub_connection(:get, { "data" => { "balances" => [{ "asset" => "BTC" }] } })
    result = @client.get_balances
    assert result.success?
  end

  def test_place_order
    stub_connection(:post, { "data" => { "orderId" => "123" } })
    result = @client.place_order(symbol: "BTC-USDT", side: "BUY", type: "MARKET", quantity: "0.001")
    assert result.success?
  end

  def test_get_order
    stub_connection(:get, { "data" => { "orderId" => "123" } })
    result = @client.get_order(symbol: "BTC-USDT", order_id: "123")
    assert result.success?
  end

  # BingX rejects with HTTP 200 and a non-zero `code`. Without a guard the rejection was read as
  # a placed order and handed back as order_id "BTC-USDT-" (nil id), so a bot recorded a trade
  # that does not exist and then polled a malformed id forever.
  def test_place_order_fails_on_nonzero_code
    stub_connection(:post, { "code" => 100004, "msg" => "insufficient balance" })
    result = @client.place_order(symbol: "BTC-USDT", side: "BUY", type: "MARKET", quantity: "0.001")
    assert result.failure?
    assert_includes result.errors.first, "insufficient balance"
  end

  def test_get_order_fails_on_nonzero_code
    stub_connection(:get, { "code" => 80016, "msg" => "Order does not exist" })
    result = @client.get_order(symbol: "BTC-USDT", order_id: "123")
    assert result.failure?
    assert_includes result.errors.first, "Order does not exist"
  end

  def test_place_order_succeeds_on_zero_code
    stub_connection(:post, { "code" => 0, "data" => { "orderId" => "123" } })
    result = @client.place_order(symbol: "BTC-USDT", side: "BUY", type: "MARKET", quantity: "0.001")
    assert result.success?
    assert_equal "BTC-USDT-123", result.data[:order_id]
  end

  def test_cancel_order
    stub_connection(:post, { "data" => { "orderId" => "123" } })
    result = @client.cancel_order(symbol: "BTC-USDT", order_id: "123")
    assert result.success?
  end

  def test_withdraw
    stub_connection(:post, { "data" => { "id" => "w1" } })
    result = @client.withdraw(coin: "BTC", address: "addr", amount: "0.1")
    assert result.success?
  end

  def test_get_trade_fills
    stub_connection(:get, { "data" => [{ "tradeId" => "t1" }] })
    result = @client.get_trade_fills(symbol: "BTC-USDT")
    assert result.success?
  end

  def test_deposit_history
    stub_connection(:get, [{ "coin" => "BTC" }])
    result = @client.deposit_history
    assert result.success?
  end

  def test_withdraw_history
    stub_connection(:get, [{ "coin" => "ETH" }])
    result = @client.withdraw_history
    assert result.success?
  end

  private

  def stub_connection(method, body)
    response = stub(body: body)
    connection = stub
    connection.stubs(method).returns(response)
    @client.instance_variable_set(:@connection, connection)
  end
end
