# frozen_string_literal: true

require "test_helper"

class Honeymaker::Clients::KrakenFuturesTest < Minitest::Test
  def setup
    @client = Honeymaker::Clients::KrakenFutures.new(
      api_key: "test_key",
      api_secret: Base64.strict_encode64("test_secret_key_1234567890123456")
    )
  end

  def test_url
    assert_equal "https://futures.kraken.com", Honeymaker::Clients::KrakenFutures::URL
  end

  def test_get_accounts
    stub_connection(:get, { "result" => "success", "accounts" => {} })
    result = @client.get_accounts
    assert result.success?
  end

  def test_get_fills
    stub_connection(:get, { "result" => "success", "fills" => [] })
    result = @client.get_fills
    assert result.success?
  end

  def test_get_open_positions
    stub_connection(:get, { "result" => "success", "openPositions" => [] })
    result = @client.get_open_positions
    assert result.success?
  end

  def test_historical_funding_rates
    stub_connection(:get, { "result" => "success", "rates" => [] })
    result = @client.historical_funding_rates(symbol: "PF_XBTUSD")
    assert result.success?
  end

  def test_client_registered
    client = Honeymaker.client("kraken_futures", api_key: "k", api_secret: Base64.strict_encode64("s" * 32))
    assert_instance_of Honeymaker::Clients::KrakenFutures, client
  end

  private

  def stub_connection(method, body)
    response = stub(body: body)
    connection = stub
    connection.stubs(method).returns(response)
    @client.instance_variable_set(:@connection, connection)
  end
end
