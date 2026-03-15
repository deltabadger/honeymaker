# frozen_string_literal: true

require "test_helper"

class Honeymaker::ResultTest < Minitest::Test
  def test_success_is_successful
    result = Honeymaker::Result::Success.new("data")
    assert result.success?
    refute result.failure?
    assert_equal "data", result.data
    assert_empty result.errors
  end

  def test_success_with_nil_data
    result = Honeymaker::Result::Success.new
    assert result.success?
    assert_nil result.data
  end

  def test_failure_is_not_successful
    result = Honeymaker::Result::Failure.new("something went wrong")
    refute result.success?
    assert result.failure?
    assert_equal ["something went wrong"], result.errors
  end

  def test_failure_with_multiple_errors
    result = Honeymaker::Result::Failure.new("error1", "error2")
    assert_equal ["error1", "error2"], result.errors
  end

  def test_failure_with_default_error
    result = Honeymaker::Result::Failure.new
    assert_equal ["Error"], result.errors
  end

  def test_failure_with_data
    result = Honeymaker::Result::Failure.new("err", data: { partial: true })
    assert_equal({ partial: true }, result.data)
    assert_equal ["err"], result.errors
  end
end
