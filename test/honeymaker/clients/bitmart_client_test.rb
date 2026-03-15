# frozen_string_literal: true

require "test_helper"

class Honeymaker::Clients::BitMartTest < Minitest::Test
  def setup
    @client = Honeymaker::Clients::BitMart.new(
      api_key: "test_key", api_secret: "test_secret", memo: "test_memo"
    )
  end

  def test_url
    assert_equal "https://api-cloud.bitmart.com", Honeymaker::Clients::BitMart::URL
  end

  def test_accepts_memo
    assert_equal "test_memo", @client.memo
  end

  def test_get_symbols_details
    stub_connection(:get, { "data" => { "symbols" => [{ "symbol" => "BTC_USDT" }] } })
    result = @client.get_symbols_details
    assert result.success?
  end

  def test_get_ticker
    stub_connection(:get, { "data" => [{ "symbol" => "BTC_USDT" }] })
    result = @client.get_ticker(symbol: "BTC_USDT")
    assert result.success?
  end

  def test_get_wallet
    stub_connection(:get, { "data" => { "wallet" => [{ "id" => "BTC" }] } })
    result = @client.get_wallet
    assert result.success?
  end

  def test_submit_order
    stub_connection(:post, { "data" => { "order_id" => 123 } })
    result = @client.submit_order(symbol: "BTC_USDT", side: "buy", type: "market", notional: "100")
    assert result.success?
  end

  def test_get_order
    stub_connection(:post, { "data" => { "order_id" => 123 } })
    result = @client.get_order(order_id: "123")
    assert result.success?
  end

  def test_cancel_order
    stub_connection(:post, { "data" => true })
    result = @client.cancel_order(symbol: "BTC_USDT", order_id: "123")
    assert result.success?
  end

  def test_withdraw
    stub_connection(:post, { "data" => { "withdraw_id" => "w1" } })
    result = @client.withdraw(currency: "BTC", amount: "0.1", address: "addr")
    assert result.success?
  end

  def test_signed_headers_include_memo_in_signature
    ts = "1234567890"
    pre_sign = "#{ts}#test_memo#body"
    headers = @client.send(:signed_headers, ts, pre_sign)
    assert_equal "test_key", headers[:"X-BM-KEY"]
    assert headers.key?(:"X-BM-SIGN")
  end

  private

  def stub_connection(method, body)
    response = stub(body: body)
    connection = stub
    connection.stubs(method).returns(response)
    @client.instance_variable_set(:@connection, connection)
  end
end
