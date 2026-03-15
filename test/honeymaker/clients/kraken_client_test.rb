# frozen_string_literal: true

require "test_helper"

class Honeymaker::Clients::KrakenTest < Minitest::Test
  def setup
    @client = Honeymaker::Clients::Kraken.new(
      api_key: "test_key",
      api_secret: Base64.strict_encode64("test_secret_key_1234567890123456")
    )
  end

  def test_url
    assert_equal "https://api.kraken.com", Honeymaker::Clients::Kraken::URL
  end

  def test_get_tradable_asset_pairs
    stub_connection(:get, { "error" => [], "result" => { "XBTUSDT" => { "altname" => "XBTUSDT" } } })
    result = @client.get_tradable_asset_pairs
    assert result.success?
    assert result.data["result"].key?("XBTUSDT")
  end

  def test_get_ticker_information
    stub_connection(:get, { "error" => [], "result" => { "XBTUSDT" => { "a" => ["50000"] } } })
    result = @client.get_ticker_information(pair: "XBTUSDT")
    assert result.success?
  end

  def test_add_order
    stub_connection(:post, { "error" => [], "result" => { "txid" => ["ORDER-123"] } })
    result = @client.add_order(ordertype: "market", type: "buy", volume: "0.001", pair: "XBTUSDT")
    assert result.success?
    assert_equal ["ORDER-123"], result.data["result"]["txid"]
  end

  def test_cancel_order
    stub_connection(:post, { "error" => [], "result" => { "count" => 1 } })
    result = @client.cancel_order(txid: "ORDER-123")
    assert result.success?
  end

  def test_get_extended_balance
    stub_connection(:post, { "error" => [], "result" => { "XXBT" => { "balance" => "0.5" } } })
    result = @client.get_extended_balance
    assert result.success?
  end

  def test_private_headers_produce_signature
    headers = @client.send(:private_headers, "/0/private/Balance", "nonce=12345")
    assert headers.key?(:"API-Key")
    assert headers.key?(:"API-Sign")
    assert_equal "test_key", headers[:"API-Key"]
  end

  def test_public_headers_no_auth
    client = Honeymaker::Clients::Kraken.new
    headers = client.send(:public_headers)
    refute headers.key?(:"API-Key")
  end

  private

  def stub_connection(method, body)
    response = stub(body: body)
    connection = stub
    connection.stubs(method).returns(response)
    @client.instance_variable_set(:@connection, connection)
  end
end
