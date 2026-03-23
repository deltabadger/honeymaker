# frozen_string_literal: true

require "test_helper"

class Honeymaker::Clients::GeminiTest < Minitest::Test
  def setup
    @client = Honeymaker::Clients::Gemini.new(api_key: "test_key", api_secret: "test_secret")
  end

  def test_url
    assert_equal "https://api.gemini.com", Honeymaker::Clients::Gemini::URL
  end

  def test_get_symbols
    stub_connection(:get, ["btcusd", "ethusd"])
    result = @client.get_symbols
    assert result.success?
    assert_includes result.data, "btcusd"
  end

  def test_get_symbol_details
    stub_connection(:get, { "symbol" => "BTCUSD", "base_currency" => "BTC" })
    result = @client.get_symbol_details(symbol: "btcusd")
    assert result.success?
  end

  def test_get_ticker
    stub_connection(:get, { "last" => "50000" })
    result = @client.get_ticker(symbol: "btcusd")
    assert result.success?
  end

  def test_get_balances
    stub_connection(:post, [{ "currency" => "BTC", "amount" => "0.5" }])
    result = @client.get_balances
    assert result.success?
  end

  def test_new_order
    stub_connection(:post, { "order_id" => "123" })
    result = @client.new_order(symbol: "btcusd", amount: "0.001", price: "50000", side: "buy", type: "exchange limit")
    assert result.success?
  end

  def test_order_status
    stub_connection(:post, { "order_id" => "123", "is_live" => false })
    result = @client.order_status(order_id: "123")
    assert result.success?
  end

  def test_cancel_order
    stub_connection(:post, { "order_id" => "123", "is_cancelled" => true })
    result = @client.cancel_order(order_id: "123")
    assert result.success?
  end

  def test_withdraw
    stub_connection(:post, { "destination" => "addr", "amount" => "0.1" })
    result = @client.withdraw(currency: "btc", address: "addr", amount: "0.1")
    assert result.success?
  end

  def test_get_my_trades
    stub_connection(:post, [{ "tid" => 123, "price" => "50000" }])
    result = @client.get_my_trades(symbol: "btcusd")
    assert result.success?
  end

  def test_get_transfers
    stub_connection(:post, [{ "type" => "Deposit", "currency" => "BTC" }])
    result = @client.get_transfers
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
