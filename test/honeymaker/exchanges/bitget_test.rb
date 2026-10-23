# frozen_string_literal: true

require "test_helper"

class Honeymaker::Exchanges::BitgetTest < Minitest::Test
  include FixtureHelper

  def setup
    @exchange = Honeymaker::Exchanges::Bitget.new
  end

  def test_get_tickers_info_parses_response
    body = load_fixture("bitget_symbols.json")
    stub_connection(body)

    result = @exchange.get_tickers_info

    assert result.success?
    assert_equal 2, result.data.size

    ticker = result.data.first
    assert_equal "BTCUSDT", ticker[:ticker]
    assert_equal "BTC", ticker[:base]
    assert_equal "USDT", ticker[:quote]
    assert_equal "0.00001", ticker[:minimum_base_size]
    assert_equal "5", ticker[:minimum_quote_size]
    assert_equal "9000", ticker[:maximum_base_size]
    assert_equal 6, ticker[:base_decimals]
    assert_equal 8, ticker[:quote_decimals]
    assert_equal 2, ticker[:price_decimals]
    assert ticker[:available]
    assert ticker[:trading_enabled]
  end

  def test_offline_symbol_listed_but_not_trading_enabled
    body = load_fixture("bitget_symbols.json")
    stub_connection(body)

    result = @exchange.get_tickers_info

    eth = result.data.find { |t| t[:ticker] == "ETHUSDT" }
    assert eth[:available]          # still listed
    refute eth[:trading_enabled]    # but not trading
  end

  def test_get_bid_ask_parses_response
    body = load_fixture("bitget_tickers.json")
    stub_connection(body)

    result = @exchange.get_bid_ask("BTCUSDT")

    assert result.success?
    assert_equal BigDecimal("67123.45"), result.data[:bid]
    assert_equal BigDecimal("67125.67"), result.data[:ask]
  end

  def test_usdt_minimum_on_a_usdt_pair_is_not_converted_and_no_prices_are_read
    connection = stub
    connection.expects(:get).with("/api/v2/spot/public/symbols").returns(stub(body: load_fixture("bitget_symbols.json")))
    @exchange.instance_variable_set(:@connection, connection)

    assert_equal "5", @exchange.get_tickers_info.data.first[:minimum_quote_size]
  end

  def test_non_usdt_quote_converted_at_the_quotes_own_usdt_price
    tickers = [{ "symbol" => "BTCUSDT", "lastPr" => "50000" },
               { "symbol" => "ETHBTC", "lastPr" => "0.05" }] # the traded pair's price: never used
    data = quote_minimums({ "ETHBTC" => "BTC" }, tickers)
    assert_equal BigDecimal("0.0001"), BigDecimal(data["ETHBTC"])
  end

  def test_inverse_usdt_quote_pair_multiplies
    data = quote_minimums({ "BTCTRY" => "TRY" }, [{ "symbol" => "USDTTRY", "lastPr" => "40" }])
    assert_equal BigDecimal("200"), BigDecimal(data["BTCTRY"])
  end

  def test_missing_price_leaves_the_minimum_to_the_venue
    data = quote_minimums({ "ETHBTC" => "BTC", "XEUR" => "EUR" },
                          [{ "symbol" => "BTCUSDT", "lastPr" => "0" }, { "symbol" => "ETHBTC", "lastPr" => "0.05" }])
    assert_equal "0", data["ETHBTC"]
    assert_equal "0", data["XEUR"]
  end

  def test_failed_price_read_falls_back_like_a_missing_price
    data = quote_minimums({ "ETHBTC" => "BTC", "BTCUSDT" => "USDT" }, Faraday::ServerError.new("boom"))
    assert_equal "0", data["ETHBTC"]
    assert_equal "5", data["BTCUSDT"]
  end

  private

  # symbol => quote rows, each with minTradeUSDT 5; tickers is the market's ticker list or the
  # error its read raises. Returns symbol => minimum_quote_size.
  def quote_minimums(pairs, tickers)
    products = pairs.map do |symbol, quote|
      load_fixture("bitget_symbols.json")["data"].first.merge("symbol" => symbol, "quoteCoin" => quote, "minTradeUSDT" => "5")
    end
    connection = stub
    connection.stubs(:get).with("/api/v2/spot/public/symbols").returns(stub(body: { "data" => products }))
    if tickers.is_a?(Exception)
      connection.stubs(:get).with("/api/v2/spot/market/tickers").raises(tickers)
    else
      connection.stubs(:get).with("/api/v2/spot/market/tickers").returns(stub(body: { "data" => tickers }))
    end
    @exchange.instance_variable_set(:@connection, connection)
    result = @exchange.get_tickers_info
    assert result.success?, result.errors.inspect
    result.data.to_h { |t| [t[:ticker], t[:minimum_quote_size]] }
  end

  def stub_connection(body)
    response = stub(body: body)
    connection = stub
    connection.stubs(:get).returns(response)
    @exchange.instance_variable_set(:@connection, connection)
  end
end
