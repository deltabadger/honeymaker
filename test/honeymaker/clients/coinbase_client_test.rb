# frozen_string_literal: true

require "test_helper"

class Honeymaker::Clients::CoinbaseTest < Minitest::Test
  def setup
    # Use ECDSA key for testing
    @key = OpenSSL::PKey::EC.generate("prime256v1")
    @client = Honeymaker::Clients::Coinbase.new(
      api_key: "test_key",
      api_secret: @key.to_pem
    )
  end

  def test_url
    assert_equal "https://api.coinbase.com", Honeymaker::Clients::Coinbase::URL
  end

  def test_get_order
    stub_connection(:get, { "order" => {
      "order_id" => "abc", "status" => "FILLED", "order_type" => "MARKET", "side" => "BUY",
      "average_filled_price" => "50000", "filled_size" => "0.001",
      "total_value_after_fees" => "50", "outstanding_hold_amount" => "0",
      "order_configuration" => { "market_market_ioc" => { "quote_size" => "50" } }
    } })
    result = @client.get_order(order_id: "abc")
    assert result.success?
    assert_equal "abc", result.data[:order_id]
    assert_equal :closed, result.data[:status]
  end

  def test_create_order
    stub_connection(:post, { "success" => true, "success_response" => { "order_id" => "xyz" } })
    result = @client.create_order(
      client_order_id: "c1", product_id: "BTC-USD",
      side: "BUY", order_configuration: { market_market_ioc: { quote_size: "100" } }
    )
    assert result.success?
    assert_equal "xyz", result.data[:order_id]
  end

  def test_cancel_orders
    stub_connection(:post, { "results" => [{ "success" => true }] })
    result = @client.cancel_orders(order_ids: ["abc"])
    assert result.success?
  end

  def test_list_public_products
    stub_connection(:get, { "products" => [{ "product_id" => "BTC-USD" }] })
    result = @client.list_public_products
    assert result.success?
  end

  def test_get_public_product
    stub_connection(:get, { "product_id" => "BTC-USD" })
    result = @client.get_public_product(product_id: "BTC-USD")
    assert result.success?
  end

  def test_get_api_key_permissions
    stub_connection(:get, { "can_trade" => true })
    result = @client.get_api_key_permissions
    assert result.success?
  end

  def test_list_accounts
    stub_connection(:get, { "accounts" => [] })
    result = @client.list_accounts
    assert result.success?
  end

  def test_send_money
    stub_connection(:post, { "data" => { "id" => "tx1" } })
    result = @client.send_money(account_id: "acc1", to: "addr", amount: "0.1", currency: "BTC")
    assert result.success?
  end

  def test_list_fills
    stub_connection(:get, { "fills" => [{ "trade_id" => "f1", "product_id" => "BTC-USD" }] })
    result = @client.list_fills(product_id: "BTC-USD")
    assert result.success?
    assert_equal "f1", result.data["fills"].first["trade_id"]
  end

  def test_list_transactions
    stub_connection(:get, { "data" => [{ "id" => "tx1", "type" => "send" }] })
    result = @client.list_transactions(account_id: "acc1")
    assert result.success?
    assert_equal "tx1", result.data["data"].first["id"]
  end

  def test_handles_api_error
    connection = stub
    connection.stubs(:get).raises(Faraday::ClientError.new("401", { status: 401, body: "Unauthorized" }))
    @client.instance_variable_set(:@connection, connection)
    result = @client.list_accounts
    assert result.failure?
  end

  def test_ecdsa_key_detected
    assert @client.send(:ecdsa_key?)
  end

  def test_non_ecdsa_key_not_detected
    client = Honeymaker::Clients::Coinbase.new(api_key: "k", api_secret: "not-a-pem-key")
    refute client.send(:ecdsa_key?)
  end

  def test_ed25519_returns_nil_without_rbnacl
    client = Honeymaker::Clients::Coinbase.new(api_key: "k", api_secret: Base64.encode64("short"))
    # rbnacl may or may not be installed; either way should not raise
    result = client.send(:ed25519_signing_key)
    # Returns nil if rbnacl not installed or key is invalid
    assert_nil result
  end

  def test_unauthenticated_headers
    client = Honeymaker::Clients::Coinbase.new
    stub_connection_on(client, :get, { "products" => [] })
    result = client.list_public_products
    assert result.success?
  end

  private

  def stub_connection(method, body)
    response = stub(body: body)
    connection = stub
    connection.stubs(method).returns(response)
    @client.instance_variable_set(:@connection, connection)
  end

  def stub_connection_on(client, method, body)
    response = stub(body: body)
    connection = stub
    connection.stubs(method).returns(response)
    client.instance_variable_set(:@connection, connection)
  end
end
