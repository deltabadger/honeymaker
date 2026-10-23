# frozen_string_literal: true

require "test_helper"

class Honeymaker::FloorsTest < Minitest::Test
  F = Honeymaker::Floors

  def test_max_of_published_and_floor
    assert_equal 5, F.minimum_quote(venue: "kraken", quote: "USD", published: "0.5")
    assert_equal "12.5", F.minimum_quote(venue: "kraken", quote: "USD", published: "12.5")
    assert_equal 5, F.minimum_quote(venue: "kraken", quote: "USD", published: "5.0") # tie: the floor
  end

  def test_missing_or_unreadable_published_gives_the_floor
    assert_equal 5, F.minimum_quote(venue: "kraken", quote: "USD")
    assert_equal 5, F.minimum_quote(venue: "kraken", quote: "USD", published: "abc")
  end

  def test_no_floor_keeps_published
    assert_equal "0.1", F.minimum_quote(venue: "kraken", quote: "FOO", published: "0.1")
    assert_equal "3", F.minimum_quote(venue: "binance", quote: "USDT", published: "3")
    assert_nil F.minimum_quote(venue: "binance", quote: "USDT")
  end

  def test_alpaca_floor_is_keyed_by_asset_class
    assert_equal 10, F.minimum_quote(venue: "alpaca", quote: "USD", asset_class: "crypto", published: "1")
    assert_equal 10, F.minimum_quote(venue: :alpaca, quote: "USD", asset_class: :crypto)
    assert_equal "1", F.minimum_quote(venue: "alpaca", quote: "USD", asset_class: "stock", published: "1")
    assert_nil F.minimum_quote(venue: "alpaca", quote: "USD", asset_class: "stock")
  end

  def test_hyperliquid_floor_covers_every_quote
    assert_equal 10, F.minimum_quote(venue: "hyperliquid", quote: "USDC")
    assert_equal 10, F.minimum_quote(venue: "hyperliquid", quote: "USDT0", published: "1")
    assert_equal "25", F.minimum_quote(venue: "hyperliquid", quote: "USDC", published: "25")
  end
end
