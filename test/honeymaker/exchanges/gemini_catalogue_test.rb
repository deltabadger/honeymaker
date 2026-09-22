# frozen_string_literal: true

require "test_helper"

# The set-aside rule, driven through honeymaker's real middleware stack: one symbol Gemini lists but
# cannot describe is left out and named, and never fails the whole catalogue.
class Honeymaker::Exchanges::GeminiCatalogueTest < Minitest::Test
  JSON_CT = { "Content-Type" => "application/json" }.freeze

  def detail(sym, base, quote, **over)
    { "symbol" => sym.upcase, "base_currency" => base, "quote_currency" => quote, "tick_size" => "0.00000001",
      "quote_increment" => "0.01", "min_order_size" => "0.00001", "status" => "open", "product_type" => "spot" }.merge(over.transform_keys(&:to_s))
  end

  def exchange_with(symbols, &details)
    stubs = Faraday::Adapter::Test::Stubs.new do |s|
      s.get("/v1/symbols") { [200, JSON_CT, JSON.dump(symbols)] }
      symbols.each { |sym| s.get("/v1/symbols/details/#{sym}") { details.call(sym) } }
    end
    ex = Honeymaker::Exchanges::Gemini.new
    @sleeps = sleeps = []
    ex.define_singleton_method(:sleep) { |s| sleeps << s }
    conn = Faraday.new(url: "https://api.gemini.com") do |c|
      c.request :json; c.response :json; c.response :raise_error; c.adapter :test, stubs
    end
    ex.instance_variable_set(:@connection, conn)
    ex
  end

  def ok(sym)
    base = sym[0..-4].upcase
    [200, JSON_CT, JSON.dump(detail(sym, base, "USD"))]
  end

  def test_incident_replay_sets_gramsgd_aside_and_reads_the_rest
    body = '{"result":"error","reason":"InvalidSymbol","message":"Received unsupported symbol \'gramsgd\'"}'
    ex = exchange_with(%w[btcusd gramsgd ethusd]) { |s| s == "gramsgd" ? [400, JSON_CT, body] : ok(s) }
    r = ex.get_tickers_info
    assert r.success?
    assert_equal %w[BTCUSD ETHUSD], r.data.map { |t| t[:ticker] }
    assert_equal({ "GRAMSGD" => "HTTP 400 #{body}" }, ex.unreadable_symbols)
    assert_equal [0.5] * 4, @sleeps, "a 400 is not retried"
  end

  def test_text_plain_details_are_set_aside_not_read_as_non_spot
    ex = exchange_with(%w[btcusd ethusd]) do |s|
      s == "ethusd" ? [200, { "Content-Type" => "text/plain" }, JSON.dump(detail("ethusd", "ETH", "USD"))] : ok(s)
    end
    r = ex.get_tickers_info
    assert r.success?
    assert_equal %w[BTCUSD], r.data.map { |t| t[:ticker] }
    assert_match(/not an object/, ex.unreadable_symbols["ETHUSD"])
  end

  def test_garbage_shapes_are_each_set_aside
    shapes = {
      "aaausd" => [200, JSON_CT, JSON.dump(detail("aaausd", "AAA", "USD").except("product_type"))],
      "bbbusd" => [200, { "Content-Type" => "text/html" }, "<html>oops</html>"],
      "cccusd" => [200, JSON_CT, "{not json"],
      "dddusd" => [200, JSON_CT, JSON.dump([1, 2])],
      "eeeusd" => [200, JSON_CT, JSON.dump(detail("eeeusd", nil, "USD"))],
      "fffusd" => [403, { "Content-Type" => "text/html" }, "<html>blocked</html>"],
      "gggusd" => [404, JSON_CT, "{}"],
      "hhhusd" => [200, JSON_CT, JSON.dump(detail("hhhusd", "HHH", "USD", product_type: ""))],
      "iiiusd" => [200, JSON_CT, JSON.dump(detail("iiiusd", "III", "USD").except("status"))]
    }
    ex = exchange_with(%w[btcusd] + shapes.keys) { |s| shapes[s] || ok(s) }
    r = ex.get_tickers_info
    assert r.success?, r.errors.inspect
    assert_equal %w[BTCUSD], r.data.map { |t| t[:ticker] }
    assert_equal shapes.keys.map(&:upcase).sort, ex.unreadable_symbols.keys.sort
  end

  def test_one_symbol_without_answer_is_set_aside_after_its_retries
    ex = exchange_with(%w[btcusd ethusd solusd]) { |s| s == "ethusd" ? [503, JSON_CT, "{}"] : ok(s) }
    r = ex.get_tickers_info
    assert r.success?
    assert_equal %w[BTCUSD SOLUSD], r.data.map { |t| t[:ticker] }
    assert_equal [0.5, 0.5, 0.5, 2, 0.5, 4, 0.5, 0.5], @sleeps
  end

  def test_the_no_answer_budget_fails_the_whole_catalogue
    syms = (1..12).map { |i| format("x%02dusd", i) }
    requested = []
    ex = exchange_with(syms) { |s| requested << s; [503, JSON_CT, "{}"] }
    r = ex.get_tickers_info
    assert r.failure?
    assert_equal({ status: 503 }, r.data)
    assert_equal 10, requested.uniq.size, "stops at the budget"
  end

  def test_nine_no_answers_among_readable_symbols_still_succeed
    syms = (1..9).flat_map { |i| [format("x%02dusd", i), format("y%02dusd", i)] }
    ex = exchange_with(syms) { |s| s.start_with?("x") ? [503, JSON_CT, "{}"] : ok(s) }
    r = ex.get_tickers_info
    assert r.success?, r.errors.inspect
    assert_equal 9, r.data.size
    assert_equal 9, ex.unreadable_symbols.size
  end

  def test_every_pair_claimed_twice_is_set_aside_and_the_rest_kept
    twins = { "btcusd2" => %w[BTC USD], "ethusd2" => %w[ETH USD] }
    ex = exchange_with(%w[btcusd btcusd2 ethusd ethusd2 solusd]) do |s|
      twins[s] ? [200, JSON_CT, JSON.dump(detail(s, *twins[s]))] : ok(s)
    end
    r = ex.get_tickers_info
    assert r.success?
    assert_equal %w[SOLUSD], r.data.map { |t| t[:ticker] }
    assert_equal %w[BTCUSD BTCUSD2 ETHUSD ETHUSD2], ex.unreadable_symbols.keys.sort
  end

  def test_nothing_readable_is_a_failure_and_state_resets_between_runs
    ex = exchange_with(%w[btcusd]) { |_| [400, JSON_CT, "{}"] }
    assert ex.get_tickers_info.failure?
    assert_equal %w[BTCUSD], ex.unreadable_symbols.keys
    assert_equal({}, Honeymaker::Exchanges::Binance.new.unreadable_symbols)
  end
end
