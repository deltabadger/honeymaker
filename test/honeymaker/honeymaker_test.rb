# frozen_string_literal: true

require "test_helper"

class HoneymakerTest < Minitest::Test
  def test_version
    refute_nil Honeymaker::VERSION
  end

  def test_exchange_returns_correct_class
    exchange = Honeymaker.exchange("binance")
    assert_instance_of Honeymaker::Exchanges::Binance, exchange
  end

  def test_exchange_with_symbol
    exchange = Honeymaker.exchange(:kraken)
    assert_instance_of Honeymaker::Exchanges::Kraken, exchange
  end

  def test_exchange_raises_for_unknown
    assert_raises(Honeymaker::Error) { Honeymaker.exchange("unknown") }
  end

  def test_all_exchanges_registered
    assert_equal 14, Honeymaker::EXCHANGES.size
  end
end
