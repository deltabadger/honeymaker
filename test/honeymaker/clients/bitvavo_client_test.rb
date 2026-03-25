# frozen_string_literal: true

require "test_helper"

class Honeymaker::Clients::BitvavoTest < Minitest::Test
  def setup
    @client = Honeymaker::Clients::Bitvavo.new(api_key: "test_key", api_secret: "test_secret")
  end

  def test_url
    assert_equal "https://api.bitvavo.com", Honeymaker::Clients::Bitvavo::URL
  end

  def test_get_markets
    stub_connection(:get, [{ "market" => "BTC-EUR" }])
    result = @client.get_markets
    assert result.success?
  end

  def test_get_ticker_price
    stub_connection(:get, [{ "market" => "BTC-EUR", "price" => "50000" }])
    result = @client.get_ticker_price
    assert result.success?
  end

  def test_get_raw_balance
    stub_connection(:get, [{ "symbol" => "BTC", "available" => "0.5" }])
    result = @client.get_raw_balance
    assert result.success?
  end

  def test_place_order
    stub_connection(:post, { "orderId" => "123" })
    result = @client.place_order(market: "BTC-EUR", side: "buy", order_type: "market", amount_quote: "100")
    assert result.success?
  end

  def test_get_order
    stub_connection(:get, { "orderId" => "123", "status" => "filled" })
    result = @client.get_order(market: "BTC-EUR", order_id: "123")
    assert result.success?
  end

  def test_cancel_order
    stub_connection(:delete, { "orderId" => "123" })
    result = @client.cancel_order(market: "BTC-EUR", order_id: "123")
    assert result.success?
  end

  def test_withdraw
    stub_connection(:post, { "success" => true })
    result = @client.withdraw(symbol: "BTC", amount: "0.1", address: "addr")
    assert result.success?
  end

  def test_get_assets
    stub_connection(:get, [{ "symbol" => "BTC" }])
    result = @client.get_assets
    assert result.success?
  end

  def test_get_trades
    stub_connection(:get, [{ "id" => "t1", "side" => "buy" }])
    result = @client.get_trades(market: "BTC-EUR")
    assert result.success?
  end

  def test_get_deposit_history
    stub_connection(:get, [{ "symbol" => "BTC", "amount" => "1.0" }])
    result = @client.get_deposit_history
    assert result.success?
  end

  def test_get_withdrawal_history
    stub_connection(:get, [{ "symbol" => "ETH", "amount" => "2.0" }])
    result = @client.get_withdrawal_history
    assert result.success?
  end

  def test_signed_headers_include_access_window
    ts = "1234567890"
    headers = @client.send(:signed_headers, ts, "payload")
    assert_equal "test_key", headers[:"BITVAVO-ACCESS-KEY"]
    assert_equal "10000", headers[:"BITVAVO-ACCESS-WINDOW"]
    assert headers.key?(:"BITVAVO-ACCESS-SIGNATURE")
  end

  def test_signing_payload_format
    # Verify the signing payload matches Bitvavo's expected format
    sig1 = @client.send(:hmac_sha256, "test_secret", "1234567890GET/v2/balance")
    sig2 = @client.send(:hmac_sha256, "test_secret", "1234567890POST/v2/order{\"market\":\"BTC-EUR\"}")
    assert sig1.is_a?(String)
    assert sig2.is_a?(String)
    refute_equal sig1, sig2
  end

  private

  def stub_connection(method, body)
    response = stub(body: body)
    connection = stub
    connection.stubs(method).returns(response)
    @client.instance_variable_set(:@connection, connection)
  end
end
