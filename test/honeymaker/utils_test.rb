# frozen_string_literal: true

require "test_helper"

class Honeymaker::UtilsTest < Minitest::Test
  def test_decimals_with_string
    assert_equal 2, Honeymaker::Utils.decimals("0.01")
    assert_equal 8, Honeymaker::Utils.decimals("0.00000001")
    assert_equal 1, Honeymaker::Utils.decimals("0.10000000")
  end

  def test_decimals_with_integer
    assert_equal 0, Honeymaker::Utils.decimals(1)
    assert_equal 0, Honeymaker::Utils.decimals(100)
  end

  def test_decimals_with_float
    assert_equal 2, Honeymaker::Utils.decimals(0.01)
    assert_equal 1, Honeymaker::Utils.decimals(0.1)
  end

  def test_decimals_with_no_decimals
    assert_equal 0, Honeymaker::Utils.decimals("1")
    assert_equal 0, Honeymaker::Utils.decimals("10")
  end

  def test_decimals_with_nil
    assert_equal 0, Honeymaker::Utils.decimals(nil)
  end

  def test_parse_filters
    filters = [
      { "filterType" => "PRICE_FILTER", "tickSize" => "0.01" },
      { "filterType" => "LOT_SIZE", "stepSize" => "0.001" },
      { "filterType" => "NOTIONAL", "minNotional" => "5" }
    ]

    result = Honeymaker::Utils.parse_filters(filters)

    assert_equal "0.01", result[:price]["tickSize"]
    assert_equal "0.001", result[:lot_size]["stepSize"]
    assert_equal "5", result[:notional]["minNotional"]
  end

  def test_parse_filters_with_min_notional
    filters = [
      { "filterType" => "MIN_NOTIONAL", "minNotional" => "10" }
    ]

    result = Honeymaker::Utils.parse_filters(filters)

    assert_nil result[:price]
    assert_nil result[:lot_size]
    assert_equal "10", result[:notional]["minNotional"]
  end

  def test_parse_filters_empty
    result = Honeymaker::Utils.parse_filters([])

    assert_nil result[:price]
    assert_nil result[:lot_size]
    assert_nil result[:notional]
  end
end
