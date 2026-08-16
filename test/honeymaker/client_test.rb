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
    assert_equal ["StandardError: boom"], result.errors
  end

  # A bug in this gem, in a vendor gem, or in the caller is NOT an exchange error, but it lands in
  # the same Result::Failure. Callers classify failure text to decide "out of funds" / "bad key" /
  # "retry me", so an unlabelled TypeError reads as something the venue said and gets filed and
  # reported as one. Naming the class makes the true source unmistakable, and the flag lets a
  # caller refuse to classify it at all.
  def test_with_rescue_names_the_exception_class_for_non_api_errors
    client = Honeymaker::Client.new
    result = client.send(:with_rescue) { raise TypeError, "String can't be coerced into Float" }
    assert result.failure?
    assert_equal ["TypeError: String can't be coerced into Float"], result.errors
    assert result.data[:client_error], "a local exception must be flagged, not passed off as the venue's"
  end

  def test_with_rescue_labels_an_empty_message_with_its_class
    client = Honeymaker::Client.new
    result = client.send(:with_rescue) { raise NoMethodError, "" }
    assert result.failure?
    assert_equal ["NoMethodError"], result.errors
  end

  # Network failures reach callers through this branch too, and the transient-retry matchers key
  # off substrings of them. Prefixing must not break that.
  def test_with_rescue_keeps_network_substrings_matchable
    client = Honeymaker::Client.new
    result = client.send(:with_rescue) { raise Net::ReadTimeout, "Net::ReadTimeout with #<TCPSocket:(closed)>" }
    assert_includes result.errors.first, "Net::ReadTimeout"
  end

  # An exchange error is not ours: it must stay unflagged and unprefixed so the venue's own text
  # reaches the classifiers verbatim.
  def test_with_rescue_does_not_flag_api_errors
    client = Honeymaker::Client.new
    result = client.send(:with_rescue) { raise Faraday::TimeoutError, "timeout" }
    assert result.failure?
    assert_nil result.data[:client_error]
  end

  def test_hmac_sha256
    client = Honeymaker::Client.new
    sig = client.send(:hmac_sha256, "secret", "data")
    expected = OpenSSL::HMAC.hexdigest("sha256", "secret", "data")
    assert_equal expected, sig
  end
end
