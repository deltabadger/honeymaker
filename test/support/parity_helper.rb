# frozen_string_literal: true

require "bigdecimal"
require_relative "venue_double"

# Same-process parity; the legacy client is the oracle. Exact comparison: class, value, String
# encoding, Float#eql?, BigDecimal sign, Hash key order.
module ParityHelper
  def self.included(base)
    base.class_eval do
      def setup
        Honeymaker::Native.load!
        require "honeymaker/native/kraken"
      rescue LoadError
        raise if ENV["HONEYMAKER_REQUIRE_NATIVE"]

        skip "native extension not compiled"
      end
    end
  end

  def assert_same_ruby(expected, actual, path = "result")
    return assert_same_exception(expected, actual, path) if expected.is_a?(Exception)

    assert_equal expected.class, actual.class, "#{path}: class"
    case expected
    when Honeymaker::Result
      assert_same_ruby(expected.errors, actual.errors, "#{path}.errors")
      assert_same_ruby(expected.data, actual.data, "#{path}.data")
    when Hash
      assert_equal expected.keys, actual.keys, "#{path}: keys/order"
      expected.each { |k, v| assert_same_ruby(v, actual[k], "#{path}[#{k.inspect}]") }
    when Array
      assert_equal expected.length, actual.length, "#{path}: length"
      expected.each_with_index { |v, i| assert_same_ruby(v, actual[i], "#{path}[#{i}]") }
    when String
      assert_equal expected.encoding, actual.encoding, "#{path}: encoding"
      assert_equal expected.b, actual.b, "#{path}: bytes"
    when Float
      assert expected.eql?(actual) || (expected.nan? && actual.nan?), "#{path}: #{expected} vs #{actual}"
    when BigDecimal
      assert_equal [expected.to_s, expected.sign], [actual.to_s, actual.sign], "#{path}: BigDecimal"
    else
      assert_equal expected, actual, "#{path}: value"
    end
  end

  # The one documented divergence (spec §5.1): legacy's incidental NoMethodError/TypeError on a
  # nonsensical shape vs ShapeError. Never excuses decimal errors (ArgumentError must match exactly).
  def assert_same_exception(expected, actual, path)
    assert_kind_of Exception, actual, "#{path}: native returned instead of raising"
    if actual.is_a?(Honeymaker::Native::ShapeError)
      assert_includes [NoMethodError, TypeError], expected.class, "#{path}: ShapeError only replaces shape crashes"
    else
      assert_equal [expected.class, expected.message], [actual.class, actual.message], path
    end
  end
end
