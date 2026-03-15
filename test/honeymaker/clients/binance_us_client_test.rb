# frozen_string_literal: true

require "test_helper"

class Honeymaker::Clients::BinanceUsTest < Minitest::Test
  def test_inherits_from_binance
    client = Honeymaker::Clients::BinanceUs.new
    assert_kind_of Honeymaker::Clients::Binance, client
  end

  def test_url
    assert_equal "https://api.binance.us", Honeymaker::Clients::BinanceUs::URL
  end

  def test_exchange_information
    client = Honeymaker::Clients::BinanceUs.new(api_key: "k", api_secret: "s")
    response = stub(body: { "symbols" => [] })
    connection = stub
    connection.stubs(:get).returns(response)
    client.instance_variable_set(:@connection, connection)

    result = client.exchange_information
    assert result.success?
  end
end
