# frozen_string_literal: true

require "test_helper"

class ValidationTest < Minitest::Test
  def test_validate_without_credentials
    client = Honeymaker::Client.new
    result = client.validate(:trading)
    assert result.failure?
    assert_includes result.errors, "No credentials provided"
  end

  def test_validate_unknown_type
    client = Honeymaker::Client.new(api_key: "k", api_secret: "s")
    assert_raises(Honeymaker::Error) { client.validate(:unknown) }
  end

  def test_validate_rescues_errors
    client = Honeymaker::Client.new(api_key: "k", api_secret: "s")
    client.define_singleton_method(:validate_trading_credentials) { raise "boom" }
    result = client.validate(:trading)
    assert result.failure?
    assert_includes result.errors, "boom"
  end

  # Binance
  def test_binance_validate_trading_success
    client = Honeymaker::Clients::Binance.new(api_key: "k", api_secret: "s")
    # cancel_order returns error code -2011 = valid key
    stub_connection(client, :delete, { "code" => -2011, "msg" => "Unknown order" })
    result = client.validate(:trading)
    assert result.success?
  end

  def test_binance_validate_trading_failure
    client = Honeymaker::Clients::Binance.new(api_key: "k", api_secret: "s")
    stub_connection(client, :delete, { "code" => -2015, "msg" => "Invalid API-key" })
    result = client.validate(:trading)
    assert result.failure?
  end

  def test_binance_validate_read
    client = Honeymaker::Clients::Binance.new(api_key: "k", api_secret: "s")
    stub_connection(client, :get, { "ipRestrict" => true })
    result = client.validate(:read)
    assert result.success?
  end

  # Kraken
  def test_kraken_validate_trading_success
    client = Honeymaker::Clients::Kraken.new(api_key: "k", api_secret: Base64.strict_encode64("s" * 32))
    stub_connection(client, :post, { "error" => [], "result" => { "XXBT" => "0.5" } })
    result = client.validate(:trading)
    assert result.success?
  end

  def test_kraken_validate_trading_failure
    client = Honeymaker::Clients::Kraken.new(api_key: "k", api_secret: Base64.strict_encode64("s" * 32))
    stub_connection(client, :post, { "error" => ["EAPI:Invalid key"], "result" => {} })
    result = client.validate(:trading)
    assert result.failure?
  end

  # Coinbase
  def test_coinbase_validate_trading_success
    key = OpenSSL::PKey::EC.generate("prime256v1")
    client = Honeymaker::Clients::Coinbase.new(api_key: "k", api_secret: key.to_pem)
    stub_connection(client, :get, { "accounts" => [] })
    result = client.validate(:trading)
    assert result.success?
  end

  # Bybit
  def test_bybit_validate_trading_success
    client = Honeymaker::Clients::Bybit.new(api_key: "k", api_secret: "s")
    stub_connection(client, :get, { "retCode" => 0, "result" => {} })
    result = client.validate(:trading)
    assert result.success?
  end

  def test_bybit_validate_trading_failure
    client = Honeymaker::Clients::Bybit.new(api_key: "k", api_secret: "s")
    stub_connection(client, :get, { "retCode" => 10003, "retMsg" => "Invalid apikey" })
    result = client.validate(:trading)
    assert result.failure?
  end

  # MEXC
  def test_mexc_validate_trading_success
    client = Honeymaker::Clients::Mexc.new(api_key: "k", api_secret: "s")
    stub_connection(client, :get, { "balances" => [] })
    result = client.validate(:trading)
    assert result.success?
  end

  # Bitget
  def test_bitget_validate_trading_success
    client = Honeymaker::Clients::Bitget.new(api_key: "k", api_secret: "s", passphrase: "p")
    stub_connection(client, :get, { "code" => "00000", "data" => [] })
    result = client.validate(:trading)
    assert result.success?
  end

  def test_bitget_validate_trading_failure
    client = Honeymaker::Clients::Bitget.new(api_key: "k", api_secret: "s", passphrase: "p")
    stub_connection(client, :get, { "code" => "40014", "msg" => "Invalid ApiKey" })
    result = client.validate(:trading)
    assert result.failure?
  end

  # KuCoin
  def test_kucoin_validate_trading_success
    client = Honeymaker::Clients::Kucoin.new(api_key: "k", api_secret: "s", passphrase: "p")
    stub_connection(client, :get, { "code" => "200000", "data" => [] })
    result = client.validate(:trading)
    assert result.success?
  end

  # Bitvavo
  def test_bitvavo_validate_trading_success
    client = Honeymaker::Clients::Bitvavo.new(api_key: "k", api_secret: "s")
    stub_connection(client, :get, [{ "symbol" => "BTC", "available" => "0.5" }])
    result = client.validate(:trading)
    assert result.success?
  end

  # Gemini
  def test_gemini_validate_trading_success
    client = Honeymaker::Clients::Gemini.new(api_key: "k", api_secret: "s")
    stub_connection(client, :post, [{ "currency" => "BTC", "amount" => "0.5" }])
    result = client.validate(:trading)
    assert result.success?
  end

  # BingX
  def test_bingx_validate_trading_success
    client = Honeymaker::Clients::BingX.new(api_key: "k", api_secret: "s")
    stub_connection(client, :get, { "code" => 0, "data" => {} })
    result = client.validate(:trading)
    assert result.success?
  end

  # Bitrue
  def test_bitrue_validate_trading_success
    client = Honeymaker::Clients::Bitrue.new(api_key: "k", api_secret: "s")
    stub_connection(client, :get, { "balances" => [] })
    result = client.validate(:trading)
    assert result.success?
  end

  # BitMart
  def test_bitmart_validate_trading_success
    client = Honeymaker::Clients::BitMart.new(api_key: "k", api_secret: "s", memo: "m")
    stub_connection(client, :get, { "code" => 1000, "data" => {} })
    result = client.validate(:trading)
    assert result.success?
  end

  def test_bitmart_validate_trading_failure
    client = Honeymaker::Clients::BitMart.new(api_key: "k", api_secret: "s", memo: "m")
    stub_connection(client, :get, { "code" => 30004, "message" => "Unauthorized" })
    result = client.validate(:trading)
    assert result.failure?
  end

  # Hyperliquid
  def test_hyperliquid_validate_trading_success
    client = Honeymaker::Clients::Hyperliquid.new(api_key: "0xabc", api_secret: "s")
    stub_connection(client, :post, [])
    result = client.validate(:trading)
    assert result.success?
  end

  private

  def stub_connection(client, method, body)
    response = stub(body: body)
    connection = stub
    connection.stubs(method).returns(response)
    client.instance_variable_set(:@connection, connection)
  end
end
