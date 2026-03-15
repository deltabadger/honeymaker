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
end
