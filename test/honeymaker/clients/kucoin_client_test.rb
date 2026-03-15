# frozen_string_literal: true

require "test_helper"

class Honeymaker::Clients::KucoinTest < Minitest::Test
  def setup
    @client = Honeymaker::Clients::Kucoin.new(
      api_key: "test_key", api_secret: "test_secret", passphrase: "test_pass"
    )
  end

  def test_url
    assert_equal "https://api.kucoin.com", Honeymaker::Clients::Kucoin::URL
  end

  def test_accepts_passphrase
    assert_equal "test_pass", @client.passphrase
  end

  def test_get_symbols
    stub_connection(:get, { "data" => [{ "symbol" => "BTC-USDT" }] })
    result = @client.get_symbols
    assert result.success?
  end

  def test_get_all_tickers
    stub_connection(:get, { "data" => { "ticker" => [] } })
    result = @client.get_all_tickers
    assert result.success?
  end

  def test_get_accounts
    stub_connection(:get, { "data" => [{ "currency" => "BTC" }] })
    result = @client.get_accounts
    assert result.success?
  end

  def test_place_order
    stub_connection(:post, { "data" => { "orderId" => "123" } })
    result = @client.place_order(client_oid: "c1", side: "buy", symbol: "BTC-USDT", type: "market", funds: "100")
    assert result.success?
  end

  def test_get_order
    stub_connection(:get, { "data" => { "id" => "123", "isActive" => false } })
    result = @client.get_order(order_id: "123")
    assert result.success?
  end

  def test_cancel_order
    stub_connection(:delete, { "data" => { "cancelledOrderIds" => ["123"] } })
    result = @client.cancel_order(order_id: "123")
    assert result.success?
  end

  def test_withdraw
    stub_connection(:post, { "data" => { "withdrawalId" => "w1" } })
    result = @client.withdraw(currency: "BTC", address: "addr", amount: "0.1")
    assert result.success?
  end

  def test_signed_headers_include_passphrase_and_version
    ts = "1234567890"
    headers = @client.send(:signed_headers, ts, "payload")
    assert_equal "test_key", headers[:"KC-API-KEY"]
    assert_equal "2", headers[:"KC-API-KEY-VERSION"]
    assert headers.key?(:"KC-API-SIGN")
    assert headers.key?(:"KC-API-PASSPHRASE")
  end

  def test_passphrase_is_signed
    ts = "1234567890"
    headers = @client.send(:signed_headers, ts, "payload")
    # KuCoin v2 signs the passphrase with the secret
    raw_passphrase = "test_pass"
    expected = Base64.strict_encode64(OpenSSL::HMAC.digest("sha256", "test_secret", raw_passphrase))
    assert_equal expected, headers[:"KC-API-PASSPHRASE"]
  end

  private

  def stub_connection(method, body)
    response = stub(body: body)
    connection = stub
    connection.stubs(method).returns(response)
    @client.instance_variable_set(:@connection, connection)
  end
end
