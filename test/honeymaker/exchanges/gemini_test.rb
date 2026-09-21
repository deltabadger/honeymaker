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
    stub_catalogue(load_fixture("gemini_symbols.json"))

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
              .then.returns(stub(body: detail_for("ethusd")))

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

  # Gemini lists perpetual swaps in /v1/symbols with the same base and quote as the spot pair
  # (BTCGUSDPERP is BTC/GUSD). They are not spot instruments, and would take the spot pair's place.
  def test_get_tickers_info_keeps_only_spot_instruments
    connection = stub_catalogue(%w[btcusd btcusdperp])
    connection.stubs(:get).with("/v1/symbols/details/btcusdperp")
              .returns(stub(body: detail_body.merge("symbol" => "BTCUSDPERP", "product_type" => "swap")))

    result = @exchange.get_tickers_info

    assert result.success?
    assert_equal %w[BTCUSD], result.data.map { |t| t[:ticker] }
  end

  # An unclassified instrument is not assumed to be spot: the whole catalogue fails, and callers keep
  # the one they have.
  def test_get_tickers_info_fails_when_a_symbol_has_no_product_type
    connection = stub_catalogue(%w[btcusd ethusd])
    connection.stubs(:get).with("/v1/symbols/details/ethusd")
              .returns(stub(body: detail_body.except("product_type").merge("symbol" => "ETHUSD")))

    result = @exchange.get_tickers_info

    assert result.failure?
    assert_nil result.data
    assert_match(/ethusd/, result.errors.first)
  end

  def test_get_tickers_info_fails_when_two_instruments_claim_one_pair
    connection = stub_catalogue(%w[btcusd btcusd2])
    connection.stubs(:get).with("/v1/symbols/details/btcusd2")
              .returns(stub(body: detail_body.merge("symbol" => "BTCUSD2")))

    result = @exchange.get_tickers_info

    assert result.failure?
    assert_match(%r{BTC/USD}, result.errors.first)
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

  def detail_body
    load_fixture("gemini_symbol_detail.json")
  end

  def detail_response
    stub(body: detail_body)
  end

  # Every symbol resolves to the one detail fixture; a test overrides a path to make it fail.
  # Each symbol answers with the fixture's details for its own pair ("ethusd" is ETH/USD), since a
  # catalogue may not hold two instruments for one pair.
  def stub_catalogue(symbols)
    connection = stub
    connection.stubs(:get).with("/v1/symbols").returns(stub(body: symbols))
    symbols.each do |symbol|
      connection.stubs(:get).with("/v1/symbols/details/#{symbol}").returns(stub(body: detail_for(symbol)))
    end
    @exchange.instance_variable_set(:@connection, connection)
    connection
  end

  def detail_for(symbol)
    detail_body.merge("symbol" => symbol.upcase, "base_currency" => symbol[0, 3], "quote_currency" => symbol[3..])
  end

  def stub_connection(body)
    response = stub(body: body)
    connection = stub
    connection.stubs(:get).returns(response)
    @exchange.instance_variable_set(:@connection, connection)
  end
end
