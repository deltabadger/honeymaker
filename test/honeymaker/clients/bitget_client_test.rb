# frozen_string_literal: true

require "test_helper"

class Honeymaker::Clients::BitgetTest < Minitest::Test
  def setup
    @client = Honeymaker::Clients::Bitget.new(
      api_key: "test_key", api_secret: "test_secret", passphrase: "test_pass"
    )
  end

  def test_url
    assert_equal "https://api.bitget.com", Honeymaker::Clients::Bitget::URL
  end

  def test_accepts_passphrase
    assert_equal "test_pass", @client.passphrase
  end

  def test_get_coins
    stub_connection(:get, { "data" => [{ "coin" => "BTC" }] })
    result = @client.get_coins
    assert result.success?
  end

  def test_get_symbols
    stub_connection(:get, { "data" => [{ "symbol" => "BTCUSDT" }] })
    result = @client.get_symbols
    assert result.success?
  end

  def test_get_account_assets
    stub_connection(:get, { "data" => [{ "coin" => "BTC", "available" => "0.5" }] })
    result = @client.get_account_assets
    assert result.success?
  end

  def test_place_order
    stub_connection(:post, { "code" => "00000", "data" => { "orderId" => "123" } })
    result = @client.place_order(symbol: "BTCUSDT", side: "buy", order_type: "market", size: "0.001")
    assert result.success?
    assert_equal "123", result.data[:order_id]
  end

  def test_place_order_with_quote_size
    stub_connection(:post, { "code" => "00000", "data" => { "orderId" => "456" } })
    result = @client.place_order(symbol: "BTCUSDT", side: "buy", order_type: "market", quote_size: "100")
    assert result.success?
    assert_equal "456", result.data[:order_id]
  end

  def test_get_order
    stub_connection(:get, { "code" => "00000", "data" => [{
      "orderId" => "123", "orderType" => "market", "side" => "buy", "status" => "full_fill",
      "priceAvg" => "50000", "size" => "0.001", "baseVolume" => "0.001", "quoteVolume" => "50"
    }] })
    result = @client.get_order(order_id: "123")
    assert result.success?
    assert_equal :closed, result.data[:status]
  end

  def test_cancel_order
    stub_connection(:post, { "data" => { "orderId" => "123" } })
    result = @client.cancel_order(symbol: "BTCUSDT", order_id: "123")
    assert result.success?
  end

  def test_get_candles
    stub_connection(:get, { "data" => [] })
    result = @client.get_candles(symbol: "BTCUSDT", granularity: "1min")
    assert result.success?
  end

  def test_withdraw
    stub_connection(:post, { "data" => { "orderId" => "w1" } })
    result = @client.withdraw(coin: "BTC", address: "addr", size: "0.1")
    assert result.success?
  end

  def test_get_fills
    stub_connection(:get, { "data" => [{ "tradeId" => "t1" }] })
    result = @client.get_fills(symbol: "BTCUSDT")
    assert result.success?
  end

  def test_deposit_list
    stub_connection(:get, { "data" => [{ "coin" => "BTC" }] })
    result = @client.deposit_list
    assert result.success?
  end

  def test_withdrawal_list
    stub_connection(:get, { "data" => [{ "coin" => "ETH" }] })
    result = @client.withdrawal_list
    assert result.success?
  end

  def test_signed_headers_include_passphrase
    ts = "1234567890"
    headers = @client.send(:signed_headers, ts, "payload")
    assert_equal "test_key", headers[:"ACCESS-KEY"]
    assert_equal "test_pass", headers[:"ACCESS-PASSPHRASE"]
    assert_equal ts, headers[:"ACCESS-TIMESTAMP"]
    assert headers.key?(:"ACCESS-SIGN")
  end

  private

  def stub_connection(method, body)
    response = stub(body: body)
    connection = stub
    connection.stubs(method).returns(response)
    @client.instance_variable_set(:@connection, connection)
  end
end
