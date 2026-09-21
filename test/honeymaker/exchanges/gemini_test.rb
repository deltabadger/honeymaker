# frozen_string_literal: true

require "test_helper"

class Honeymaker::Exchanges::GeminiTest < Minitest::Test
  include FixtureHelper

  def setup
    @exchange = Honeymaker::Exchanges::Gemini.new
    # Recorded, not slept: the pacing and the backoff are asserted as a sequence.
    sleeps = @sleeps = []
    @exchange.define_singleton_method(:sleep) { |seconds| sleeps << seconds }
  end

  def test_get_tickers_info_parses_response
    symbols_body = load_fixture("gemini_symbols.json")
    detail_body = load_fixture("gemini_symbol_detail.json")

    symbols_response = stub(body: symbols_body)
    detail_response = stub(body: detail_body)
    connection = stub
    connection.stubs(:get).with("/v1/symbols").returns(symbols_response)
    connection.stubs(:get).with { |path| path.start_with?("/v1/symbols/details/") }.returns(detail_response)
    @exchange.instance_variable_set(:@connection, connection)

    result = @exchange.get_tickers_info

    assert result.success?
    assert_equal 2, result.data.size

    ticker = result.data.first
    assert_equal "BTCUSD", ticker[:ticker]
    assert_equal "BTC", ticker[:base]
    assert_equal "USD", ticker[:quote]
    assert_equal "0.00001", ticker[:minimum_base_size]
    assert_equal "0", ticker[:minimum_quote_size]
    assert_equal 8, ticker[:base_decimals]
    assert_equal 2, ticker[:quote_decimals]
    assert_equal 2, ticker[:price_decimals]
    assert ticker[:available]
    assert ticker[:trading_enabled]
  end

  def test_get_tickers_info_paces_every_request
    stub_catalogue(%w[btcusd ethusd])

    assert @exchange.get_tickers_info.success?
    assert_equal [0.5, 0.5, 0.5], @sleeps
  end

  def test_get_tickers_info_retries_a_dropped_detail_request
    connection = stub_catalogue(%w[btcusd ethusd])
    connection.stubs(:get).with("/v1/symbols/details/ethusd")
              .raises(Faraday::ConnectionFailed, "end of file reached")
              .then.returns(detail_response)

    result = @exchange.get_tickers_info

    assert result.success?
    assert_equal 2, result.data.size
    assert_equal [0.5, 0.5, 0.5, 2, 0.5], @sleeps
  end

  def test_get_tickers_info_retries_the_symbols_request
    connection = stub_catalogue(%w[btcusd])
    connection.stubs(:get).with("/v1/symbols")
              .raises(Faraday::TooManyRequestsError, "429")
              .then.returns(stub(body: %w[btcusd]))

    result = @exchange.get_tickers_info

    assert result.success?
    assert_equal 1, result.data.size
  end

  def test_get_tickers_info_retries_every_transient_error_class
    Honeymaker::Exchanges::Gemini::TRANSIENT_ERRORS.each do |error_class|
      setup
      connection = stub_catalogue(%w[btcusd])
      connection.stubs(:get).with("/v1/symbols/details/btcusd")
                .raises(error_class, "transient").then.returns(detail_response)

      assert @exchange.get_tickers_info.success?, "#{error_class} should be retried"
    end
  end

  # All or nothing: data-api reads a pair missing from the catalogue as delisted, so a symbol that
  # keeps failing must fail the whole catalogue, and nothing after it is fetched.
  def test_get_tickers_info_fails_whole_catalogue_when_a_symbol_keeps_failing
    connection = stub_catalogue(%w[btcusd ethusd solusd])
    connection.expects(:get).with("/v1/symbols/details/ethusd").times(3)
              .raises(Faraday::ConnectionFailed, "end of file reached")
    connection.expects(:get).with("/v1/symbols/details/solusd").never

    result = @exchange.get_tickers_info

    assert result.failure?
    assert_nil result.data
    assert_equal ["end of file reached"], result.errors
    assert_equal [0.5, 0.5, 0.5, 2, 0.5, 4, 0.5], @sleeps
  end

  def test_get_tickers_info_does_not_retry_a_non_transient_error
    connection = stub_catalogue(%w[btcusd])
    connection.expects(:get).with("/v1/symbols/details/btcusd").once
              .raises(Faraday::ResourceNotFound, "404")

    assert @exchange.get_tickers_info.failure?
  end

  def test_get_bid_ask_parses_response
    body = load_fixture("gemini_pubticker.json")
    stub_connection(body)

    result = @exchange.get_bid_ask("BTCUSD")

    assert result.success?
    assert_equal BigDecimal("67123.45"), result.data[:bid]
    assert_equal BigDecimal("67125.67"), result.data[:ask]
  end

  private

  def detail_response
    stub(body: load_fixture("gemini_symbol_detail.json"))
  end

  # Every symbol resolves to the one detail fixture; a test overrides a path to make it fail.
  def stub_catalogue(symbols)
    connection = stub
    connection.stubs(:get).with("/v1/symbols").returns(stub(body: symbols))
    connection.stubs(:get).with { |path| path.start_with?("/v1/symbols/details/") }.returns(detail_response)
    @exchange.instance_variable_set(:@connection, connection)
    connection
  end

  def stub_connection(body)
    response = stub(body: body)
    connection = stub
    connection.stubs(:get).returns(response)
    @exchange.instance_variable_set(:@connection, connection)
  end
end
