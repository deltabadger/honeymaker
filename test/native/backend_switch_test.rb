# frozen_string_literal: true

require "test_helper"
require "open3"

class Honeymaker::Native::BackendSwitchTest < Minitest::Test
  LIB = File.expand_path("../../lib", __dir__)

  def ruby(env, code)
    out, status = Open3.capture2e(env, RbConfig.ruby, "-I#{LIB}", "-rbundler/setup", "-e", code)
    [out.strip, status]
  end

  def test_flag_off_uses_ruby_and_never_loads_the_extension
    out, st = ruby({ "HONEYMAKER_NATIVE" => nil }, <<~RUBY)
      require "honeymaker"
      print [Honeymaker::CLIENTS["kraken"], Honeymaker::EXCHANGES["kraken"], Honeymaker.backend("kraken"),
             $LOADED_FEATURES.grep(/honeymaker_native\\.(so|bundle|dll)\\z/).size].join(",")
    RUBY
    assert st.success?, out
    assert_equal "Honeymaker::Clients::Kraken,Honeymaker::Exchanges::Kraken,ruby,0", out
  end

  def test_unsupported_flags_fail_at_require_time
    ["binance", " kraken, ,binance ", " KRAKEN, bybit "].each do |flag|
      out, st = ruby({ "HONEYMAKER_NATIVE" => flag }, 'require "honeymaker"')
      refute st.success?, out
      assert_match(/unsupported.*(?:binance|bybit)/i, out)
      assert_match(/supported.*kraken/i, out)
    end
  end

  def test_backend_only_reports_supported_enabled_names
    out, st = ruby({ "HONEYMAKER_NATIVE" => " KRAKEN, ,kraken " }, <<~RUBY)
      require "honeymaker"
      print [Honeymaker.backend(" KRAKEN "), Honeymaker.backend(:binance), Honeymaker.backend("unknown")].join(",")
    RUBY
    assert st.success?, out
    assert_equal "native,ruby,ruby", out
  end

  def test_flag_on_selects_native_for_kraken_only
    skip "native extension not compiled" unless Dir[File.join(LIB, "honeymaker", "**", "honeymaker_native.{so,bundle,dll}")].any?

    out, st = ruby({ "HONEYMAKER_NATIVE" => "kraken" }, <<~RUBY)
      require "honeymaker"
      print [Honeymaker.client("kraken").class, Honeymaker.exchange("kraken").class, Honeymaker.backend(:kraken),
             Honeymaker.client("binance").class, $LOADED_FEATURES.grep(/honeymaker_native\\.(so|bundle|dll)\\z/).size].join(",")
    RUBY
    assert st.success?, out
    assert_equal "Honeymaker::Native::KrakenClient,Honeymaker::Native::KrakenExchange,native,Honeymaker::Clients::Binance,1", out
  end
end
