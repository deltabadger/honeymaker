# frozen_string_literal: true

require "test_helper"

class HoneymakerClientRegistryTest < Minitest::Test
  def test_client_returns_correct_class
    client = Honeymaker.client("binance", api_key: "k", api_secret: "s")
    assert_instance_of Honeymaker::Clients::Binance, client
  end

  def test_client_with_symbol
    client = Honeymaker.client(:kraken, api_key: "k", api_secret: "s")
    assert_instance_of Honeymaker::Clients::Kraken, client
  end

  def test_client_raises_for_unknown
    assert_raises(Honeymaker::Error) { Honeymaker.client("unknown") }
  end

  def test_all_clients_registered
    assert_equal 14, Honeymaker::CLIENTS.size
  end

  def test_client_passes_credentials
    client = Honeymaker.client("binance", api_key: "my_key", api_secret: "my_secret")
    assert_equal "my_key", client.api_key
    assert_equal "my_secret", client.api_secret
  end

  def test_bitget_accepts_passphrase
    client = Honeymaker.client("bitget", api_key: "k", api_secret: "s", passphrase: "p")
    assert_equal "p", client.passphrase
  end

  def test_kucoin_accepts_passphrase
    client = Honeymaker.client("kucoin", api_key: "k", api_secret: "s", passphrase: "p")
    assert_equal "p", client.passphrase
  end

  def test_bitmart_accepts_memo
    client = Honeymaker.client("bitmart", api_key: "k", api_secret: "s", memo: "m")
    assert_equal "m", client.memo
  end
end
