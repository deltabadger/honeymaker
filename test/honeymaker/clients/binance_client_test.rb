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

  def test_account_trade_list
    stub_connection(:get, [{ "symbol" => "BTCUSDT", "id" => 123, "price" => "50000" }])
    result = @client.account_trade_list(symbol: "BTCUSDT")
    assert result.success?
    assert_equal "BTCUSDT", result.data.first["symbol"]
  end

  def test_deposit_history
    stub_connection(:get, [{ "coin" => "BTC", "amount" => "0.5", "status" => 1 }])
    result = @client.deposit_history
    assert result.success?
    assert_equal "BTC", result.data.first["coin"]
  end

  def test_withdraw_history
    stub_connection(:get, [{ "coin" => "ETH", "amount" => "1.0", "status" => 6 }])
    result = @client.withdraw_history
    assert result.success?
    assert_equal "ETH", result.data.first["coin"]
  end

  def test_convert_trade_flow
    stub_connection(:get, { "list" => [{ "quoteId" => "q1", "fromAsset" => "BTC", "toAsset" => "USDT" }] })
    result = @client.convert_trade_flow(start_time: 1710936000000, end_time: 1711022400000)
    assert result.success?
    assert_equal "q1", result.data["list"].first["quoteId"]
  end

  def test_fiat_payments
    stub_connection(:get, { "data" => [{ "orderNo" => "f1", "cryptoCurrency" => "BTC" }] })
    result = @client.fiat_payments(transaction_type: 0)
    assert result.success?
  end

  def test_fiat_orders
    stub_connection(:get, { "data" => [{ "orderNo" => "fo1", "fiatCurrency" => "USD" }] })
    result = @client.fiat_orders(transaction_type: 0)
    assert result.success?
  end

  def test_dust_log
    stub_connection(:get, { "total" => 1, "userAssetDribblets" => [{ "totalTransferedAmount" => "0.001" }] })
    result = @client.dust_log
    assert result.success?
  end

  def test_asset_dividend
    stub_connection(:get, { "rows" => [{ "asset" => "BNB", "amount" => "0.1" }], "total" => 1 })
    result = @client.asset_dividend
    assert result.success?
  end

  def test_simple_earn_flexible_rewards
    stub_connection(:get, { "rows" => [{ "asset" => "USDT", "rewards" => "0.5" }], "total" => 1 })
    result = @client.simple_earn_flexible_rewards
    assert result.success?
  end

  def test_simple_earn_locked_rewards
    stub_connection(:get, { "rows" => [{ "asset" => "ETH", "rewards" => "0.01" }], "total" => 1 })
    result = @client.simple_earn_locked_rewards
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
