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
end
