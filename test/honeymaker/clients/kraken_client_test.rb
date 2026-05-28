# frozen_string_literal: true

require "test_helper"

class Honeymaker::Clients::KrakenTest < Minitest::Test
  def setup
    Honeymaker::Clients::Kraken.reset_nonce_state! if Honeymaker::Clients::Kraken.respond_to?(:reset_nonce_state!)
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
    assert_equal "ORDER-123", result.data[:order_id]
    assert_equal ["ORDER-123"], result.data[:raw]["result"]["txid"]
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

  def test_get_trades_history
    stub_connection(:post, { "error" => [], "result" => { "trades" => { "T1" => { "pair" => "XBTUSDT" } }, "count" => 1 } })
    result = @client.get_trades_history
    assert result.success?
    assert result.data["result"]["trades"].key?("T1")
  end

  def test_get_ledgers
    stub_connection(:post, { "error" => [], "result" => { "ledger" => { "L1" => { "type" => "trade" } }, "count" => 1 } })
    result = @client.get_ledgers
    assert result.success?
    assert result.data["result"]["ledger"].key?("L1")
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

  def test_reset_nonce_state_is_available_for_test_isolation
    assert_respond_to Honeymaker::Clients::Kraken, :reset_nonce_state!
  end

  def test_nonce_is_strictly_increasing_in_a_tight_loop
    nonces = Array.new(10_000) { @client.send(:nonce) }

    assert_strictly_increasing nonces
  end

  def test_nonce_is_strictly_increasing_when_clock_is_frozen
    frozen_time = Time.utc(2026, 1, 1, 12, 0, 0)
    Time.stubs(:now).returns(frozen_time)

    nonces = Array.new(3) { @client.send(:nonce) }

    assert_strictly_increasing nonces
  end

  def test_nonce_is_strictly_increasing_across_clients_with_the_same_api_key
    frozen_time = Time.utc(2026, 1, 1, 12, 0, 0)
    Time.stubs(:now).returns(frozen_time)
    other_client = Honeymaker::Clients::Kraken.new(
      api_key: "test_key",
      api_secret: Base64.strict_encode64("test_secret_key_1234567890123456")
    )

    nonces = [
      @client.send(:nonce),
      other_client.send(:nonce),
      @client.send(:nonce),
      other_client.send(:nonce)
    ]

    assert_strictly_increasing nonces
  end

  def test_nonce_sequences_are_independent_for_different_api_keys
    frozen_time = Time.utc(2026, 1, 1, 12, 0, 0)
    Time.stubs(:now).returns(frozen_time)
    first_key_client = Honeymaker::Clients::Kraken.new(api_key: "first_key", api_secret: @client.api_secret)
    second_key_client = Honeymaker::Clients::Kraken.new(api_key: "second_key", api_secret: @client.api_secret)

    first_key_first_nonce = first_key_client.send(:nonce)
    first_key_second_nonce = first_key_client.send(:nonce)
    second_key_first_nonce = second_key_client.send(:nonce)

    assert_operator first_key_second_nonce, :>, first_key_first_nonce
    assert_equal first_key_first_nonce, second_key_first_nonce
  end

  private

  def assert_strictly_increasing(values)
    values.each_cons(2) do |previous, current|
      assert_operator current, :>, previous
    end
  end

  def stub_connection(method, body)
    response = stub(body: body)
    connection = stub
    connection.stubs(method).returns(response)
    @client.instance_variable_set(:@connection, connection)
  end
end
