# frozen_string_literal: true

require "test_helper"
require "bigdecimal"

class Honeymaker::Native::ConvertTest < Minitest::Test
  def setup
    Honeymaker::Native.load!
  rescue LoadError
    raise if ENV["HONEYMAKER_REQUIRE_NATIVE"]

    skip "native extension not compiled"
  end

  def ext = Honeymaker::Native::Ext

  def test_numeric_text_matches_ruby_to_s
    [1.0e-09, -0.0, 0.0, 1.0e20, 1688888888.1234, Float::MIN, Float::MAX,
     Float::INFINITY, -Float::INFINITY, Float::NAN, 12345678901234567890123].each do |value|
      assert_equal value.to_s, ext.to_s_for_tests(value)
    end
  end

  def test_decimal_json_and_to_s_follow_ruby
    ["0.5", 12345678901234567890123, 1.0e-09, -0.0, Float::INFINITY,
     -Float::INFINITY, Float::NAN, nil, true, false, [], { "k" => 1 }].each do |value|
      [true, false].each do |stringify|
        want = (BigDecimal(stringify ? value.to_s : value) rescue $!)
        got = (ext.decimal_convert_for_tests(value, stringify) rescue $!)
        assert_equal want.class, got.class, [value, stringify].inspect
        if want.is_a?(Exception)
          assert_equal want.message, got.message
        else
          assert_equal [want.to_s, want.sign], [got.to_s, got.sign]
        end
      end
    end
  end

  def test_decimal_arithmetic_survives_gc_in_rust_container
    [["1", "3"], ["-0.0", "2"], ["NaN", "Infinity"], ["1", "0"]].each do |a, b|
      left, right = BigDecimal(a), BigDecimal(b)
      want = [left + right, left - right, left / right]
      GC.stress = true
      got = ext.decimal_arithmetic_for_tests(a, b)
      GC.stress = false
      assert_equal want.map { |n| [n.to_s, n.sign] }, got.take(3).map { |n| [n.to_s, n.sign] }
      assert_equal left.zero?, got[3]
    end
  ensure
    GC.stress = false
  end

  def test_shape_errors
    error = assert_raises(Honeymaker::Native::ShapeError) { ext.roundtrip_for_tests({ key: 1 }) }
    assert_equal "non-string key", error.message
    error = assert_raises(Honeymaker::Native::ShapeError) { ext.roundtrip_for_tests(:unsupported) }
    assert_equal "unsupported value :unsupported", error.message
  end

  def test_false_negative_infinity_nan_and_negative_zero
    got = ext.roundtrip_for_tests([false, -Float::INFINITY, Float::NAN, -0.0])
    assert_equal false, got[0]
    assert_equal(-Float::INFINITY, got[1])
    assert_predicate got[2], :nan?
    assert_equal(-Float::INFINITY, 1.0 / got[3])
  end

  def test_json_roundtrip_is_exact
    obj = JSON.parse('{"i":12345678901234567890123,"f":1688888888.1234,"e":1e-09,"z":-0.0,"s":"\u00e9","n":null,' \
                     '"b":true,"a":[1,2.5,"x"],"big":1e400,"o":{"k":{"k2":[]}}}')
    got = ext.roundtrip_for_tests(obj)
    assert_equal obj.keys, got.keys
    obj.keys.each do |k|
      v = obj[k]
      assert_equal v.class, got[k].class, k
      assert(v.is_a?(Float) ? v.eql?(got[k]) : v == got[k], k)
    end
    assert_equal Encoding::UTF_8, got["s"].encoding
  end

  def test_decimal_is_rubys_own
    ["0.5", "-0.0000", "NaN", "Infinity", "1_000", "1e-9"].each do |s|
      want = BigDecimal(s)
      got = ext.decimal_for_tests(s)
      assert_equal [want.to_s, want.sign], [got.to_s, got.sign], s
    end
    ["", "abc", "true", "[]", "{}"].each do |s|
      want = (BigDecimal(s) rescue $!)
      got = (ext.decimal_for_tests(s) rescue $!)
      assert_equal [want.class, want.message], [got.class, got.message], s.inspect
    end
  end

  def test_survives_gc_stress_and_compaction
    obj = JSON.parse({ "rows" => (1..2_000).map { |i| { "id" => "O#{i}", "vol" => "0.#{i}", "t" => i + 0.5 } } }.to_json)
    GC.stress = true
    got = ext.roundtrip_for_tests(obj)
    GC.stress = false
    GC.compact if GC.respond_to?(:compact)
    assert_equal obj, got
  ensure
    GC.stress = false
  end
end
