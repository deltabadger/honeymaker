# frozen_string_literal: true

require "test_helper"

class Honeymaker::Native::LoaderTest < Minitest::Test
  def setup
    Honeymaker::Native.load!
  rescue LoadError => e
    raise if ENV["HONEYMAKER_REQUIRE_NATIVE"]

    skip "native extension not compiled (#{e.message})"
  end

  def test_extension_reports_the_gem_version
    assert_equal Honeymaker::VERSION, Honeymaker::Native::Ext.version
  end

  def test_flag_parsing
    Honeymaker::Native.instance_variable_set(:@enabled, nil)
    ENV["HONEYMAKER_NATIVE"] = " kraken, ,binance "
    assert_equal %w[kraken binance], Honeymaker::Native.enabled
    assert Honeymaker::Native.enabled?(:kraken)
    refute Honeymaker::Native.enabled?("bybit")
  ensure
    ENV.delete("HONEYMAKER_NATIVE")
    Honeymaker::Native.instance_variable_set(:@enabled, nil)
  end
end
