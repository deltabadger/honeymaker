# frozen_string_literal: true

require "test_helper"

class Honeymaker::ClientTest < Minitest::Test
  def test_default_options
    assert_equal 5, Honeymaker::Client::OPTIONS[:request][:open_timeout]
    assert_equal 30, Honeymaker::Client::OPTIONS[:request][:read_timeout]
    assert_equal 10, Honeymaker::Client::OPTIONS[:request][:write_timeout]
  end

  def test_authenticated_with_credentials
    client = Honeymaker::Client.new(api_key: "key", api_secret: "secret")
    assert client.send(:authenticated?)
  end

  def test_not_authenticated_without_credentials
    client = Honeymaker::Client.new
    refute client.send(:authenticated?)
  end

  def test_not_authenticated_with_empty_credentials
    client = Honeymaker::Client.new(api_key: "", api_secret: "")
    refute client.send(:authenticated?)
  end

  def test_with_rescue_wraps_success
    client = Honeymaker::Client.new
    result = client.send(:with_rescue) { { "status" => "ok" } }
    assert result.success?
    assert_equal({ "status" => "ok" }, result.data)
  end

  def test_with_rescue_wraps_faraday_error
    client = Honeymaker::Client.new
    result = client.send(:with_rescue) { raise Faraday::TimeoutError, "timeout" }
    assert result.failure?
  end

  def test_with_rescue_wraps_standard_error
    client = Honeymaker::Client.new
    result = client.send(:with_rescue) { raise StandardError, "boom" }
    assert result.failure?
    assert_equal ["boom"], result.errors
  end

  def test_hmac_sha256
    client = Honeymaker::Client.new
    sig = client.send(:hmac_sha256, "secret", "data")
    expected = OpenSSL::HMAC.hexdigest("sha256", "secret", "data")
    assert_equal expected, sig
  end
end
