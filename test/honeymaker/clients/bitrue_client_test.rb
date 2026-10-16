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

  # The /capital/ paths and /api/v1/myTrades are not in Bitrue's docs; the former redirect to the website.
  def test_account_trade_list_reads_v2
    @client.expects(:get_signed).with("/api/v2/myTrades", has_entries(symbol: "BTCUSDT", startTime: 1, endTime: 2, limit: 1000))
    @client.account_trade_list(symbol: "BTCUSDT", start_time: 1, end_time: 2, limit: 1000)
  end

  def test_deposit_history
    @client.expects(:get_signed).with("/api/v1/deposit/history", has_entries(coin: "usdt", status: 1, offset: 0, limit: 1000))
    @client.deposit_history(coin: "usdt", status: 1, offset: 0)
  end

  def test_withdraw_history
    @client.expects(:get_signed).with("/api/v1/withdraw/history", has_entries(coin: "usdt", status: 5))
    @client.withdraw_history(coin: "usdt", status: 5)
  end

  def test_withdraw_commits
    @client.expects(:post_signed).with("/api/v1/withdraw/commit",
                                       has_entries(coin: "usdt", amount: "10", addressTo: "0xabc", chainName: "TRX"))
    @client.withdraw(coin: "usdt", address: "0xabc", amount: "10", network: "TRX")
  end

  def test_get_all_coins_information_reads_exchange_info_chains
    stub_connection(:get, { "coins" => [{ "coin" => "usdt", "chainDetail" => [
      { "chain" => "OMNI", "enableWithdraw" => false, "enableDeposit" => false, "withdrawFee" => "1.28" },
      { "chain" => "TRX", "enableWithdraw" => true, "enableDeposit" => true, "withdrawFee" => "1.00",
        "minWithdraw" => "2.00", "maxWithdraw" => "2000000.00" }
    ] }] })

    result = @client.get_all_coins_information

    assert result.success?
    coin = result.data.first
    assert_equal "USDT", coin["coin"]
    assert_equal [{ "network" => "TRX", "withdrawFee" => "1.00", "withdrawMin" => "2.00", "withdrawMax" => "2000000.00",
                    "withdrawEnable" => true, "depositEnable" => true, "isDefault" => false }], coin["networkList"]
  end

  def test_ticker_24hr
    @client.expects(:get_public).with("/api/v1/ticker/24hr", { symbol: nil })
    @client.ticker_24hr
  end

  def test_candlestick_data_sends_from_idx
    @client.expects(:get_public).with("/api/v1/market/kline", has_entries(symbol: "BTCUSDT", scale: "1D", fromIdx: 5, limit: 1440))
    @client.candlestick_data(symbol: "BTCUSDT", interval: "1D", from_idx: 5, limit: 1440)
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
