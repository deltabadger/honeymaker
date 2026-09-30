# frozen_string_literal: true

require "test_helper"

class KrakenSigningSmokeTest < Minitest::Test
  def setup
    Honeymaker::Native.load!
    require_relative "../support/kraken_signing_smoke"
  rescue LoadError => e
    raise if ENV["HONEYMAKER_REQUIRE_NATIVE"]

    skip e.message
  end

  def test_real_signing_vector
    assert KrakenSigningSmoke.verify!
  end

  def test_rejects_incorrect_key_or_signature
    vector = JSON.parse(File.read(KrakenSigningSmoke::VECTORS)).find { |v| !v.fetch("api_key").empty? && !v.fetch("api_secret").empty? }
    %w[API-Key API-Sign].each do |field|
      signer = stub(sign: vector.fetch("headers").merge(field => "wrong"))
      Honeymaker::Native::Ext::Kraken.stubs(:new).with(vector.fetch("api_key"), vector.fetch("api_secret")).returns(signer)
      _, stderr = capture_io { assert_raises(SystemExit) { KrakenSigningSmoke.verify! } }
      assert_match(/#{field}/, stderr)
    end
  end
end
