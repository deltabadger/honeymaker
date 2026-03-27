# frozen_string_literal: true

require "test_helper"

class Honeymaker::ExchangeTest < Minitest::Test
  def test_get_tickers_info_raises_not_implemented
    exchange = Honeymaker::Exchange.new
    assert_raises(NotImplementedError) { exchange.get_tickers_info }
  end

  def test_with_rescue_wraps_faraday_errors
    exchange = Honeymaker::Exchange.new
    result = exchange.send(:with_rescue) { raise Faraday::TimeoutError, "timeout" }
    assert result.failure?
    assert_match(/timeout/, result.errors.first)
  end

  def test_with_rescue_wraps_standard_errors
    exchange = Honeymaker::Exchange.new
    result = exchange.send(:with_rescue) { raise StandardError, "boom" }
    assert result.failure?
    assert_equal ["boom"], result.errors
  end

  def test_with_rescue_returns_success_on_no_error
    exchange = Honeymaker::Exchange.new
    result = exchange.send(:with_rescue) { [1, 2, 3] }
    assert result.success?
    assert_equal [1, 2, 3], result.data
  end

  def test_get_bid_ask_raises_not_implemented
    exchange = Honeymaker::Exchange.new
    assert_raises(NotImplementedError) { exchange.get_bid_ask("BTCUSDT") }
  end

  def test_get_price_returns_midpoint
    exchange = Honeymaker::Exchange.new
    bid_ask = { bid: BigDecimal("100"), ask: BigDecimal("102") }
    exchange.define_singleton_method(:get_bid_ask) { |_| Honeymaker::Result::Success.new(bid_ask) }

    result = exchange.get_price("BTCUSDT")
    assert result.success?
    assert_equal BigDecimal("101"), result.data
  end

  def test_get_price_propagates_failure
    exchange = Honeymaker::Exchange.new
    exchange.define_singleton_method(:get_bid_ask) { |_| Honeymaker::Result::Failure.new("error") }

    result = exchange.get_price("BTCUSDT")
    assert result.failure?
  end

  def test_tickers_info_caches_result
    exchange = Honeymaker::Exchange.new
    tickers = [{ ticker: "BTCUSDT", base: "BTC", quote: "USDT" }]
    call_count = 0
    exchange.define_singleton_method(:get_tickers_info) do
      call_count += 1
      Honeymaker::Result::Success.new(tickers)
    end

    result1 = exchange.tickers_info
    result2 = exchange.tickers_info
    assert result1.success?
    assert result2.success?
    assert_equal 1, call_count
  end

  def test_tickers_info_does_not_cache_failure
    exchange = Honeymaker::Exchange.new
    call_count = 0
    exchange.define_singleton_method(:get_tickers_info) do
      call_count += 1
      Honeymaker::Result::Failure.new("error")
    end

    exchange.tickers_info
    exchange.tickers_info
    assert_equal 2, call_count
  end

  def test_find_ticker_returns_matching_ticker
    exchange = Honeymaker::Exchange.new
    tickers = [
      { ticker: "BTCUSDT", base: "BTC", quote: "USDT" },
      { ticker: "ETHUSDT", base: "ETH", quote: "USDT" }
    ]
    exchange.define_singleton_method(:get_tickers_info) do
      Honeymaker::Result::Success.new(tickers)
    end

    result = exchange.find_ticker("ETHUSDT")
    assert result.success?
    assert_equal "ETH", result.data[:base]
  end

  def test_find_ticker_returns_failure_for_unknown_symbol
    exchange = Honeymaker::Exchange.new
    exchange.define_singleton_method(:get_tickers_info) do
      Honeymaker::Result::Success.new([{ ticker: "BTCUSDT" }])
    end

    result = exchange.find_ticker("NOPE")
    assert result.failure?
  end

  def test_symbols_returns_base_quote_pairs
    exchange = Honeymaker::Exchange.new
    tickers = [
      { ticker: "BTCUSDT", base: "BTC", quote: "USDT" },
      { ticker: "ETHUSDT", base: "ETH", quote: "USDT" }
    ]
    exchange.define_singleton_method(:get_tickers_info) do
      Honeymaker::Result::Success.new(tickers)
    end

    result = exchange.symbols
    assert result.success?
    assert_equal [{ base: "BTC", quote: "USDT" }, { base: "ETH", quote: "USDT" }], result.data
  end

  def test_cache_ttl_defaults_to_3600
    exchange = Honeymaker::Exchange.new
    assert_equal 3600, exchange.cache_ttl
  end
end
