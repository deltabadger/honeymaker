# frozen_string_literal: true

require "test_helper"

class Honeymaker::Clients::HyperliquidTest < Minitest::Test
  def setup
    @client = Honeymaker::Clients::Hyperliquid.new
  end

  def test_url
    assert_equal "https://api.hyperliquid.xyz", Honeymaker::Clients::Hyperliquid::URL
  end

  def test_spot_meta
    stub_connection(:post, { "tokens" => [], "universe" => [] })
    result = @client.spot_meta
    assert result.success?
    assert_equal [], result.data["tokens"]
  end

  def test_spot_meta_and_asset_ctxs
    stub_connection(:post, [{ "tokens" => [] }, []])
    result = @client.spot_meta_and_asset_ctxs
    assert result.success?
  end

  def test_spot_clearinghouse_state
    stub_connection(:post, { "balances" => [] })
    result = @client.spot_clearinghouse_state(user: "0xabc")
    assert result.success?
  end

  # Hyperliquid's orderStatus body is NESTED: { "status" => "order", "order" => { "order" => {...},
  # "status" => <real status>, ... } }. The real order status, coin, sizes live under order["order"]
  # and order["status"] — NOT the top level. orderStatus carries NO "fills" key, so executed cost is
  # sourced from a bounded userFillsByTime call (only when something actually executed).

  def test_order_status_filled_parses_nested_shape_and_sources_cost_from_fills
    # Filled: remaining sz == 0, origSz is the ordered amount, real status under the wrapper.
    # statusTimestamp deliberately DIFFERS from the order timestamp so a parser that bounds
    # userFillsByTime on the wrong field fails the .with below.
    order_body = order_status_body(status: "filled", sz: "0.0", orig_sz: "0.00020",
                                   timestamp: 1781698875556, status_timestamp: 1781699999999)
    stub_connection(:post, order_body)
    # Cost comes from a BOUNDED userFillsByTime (type + start == the ORDER timestamp), summing
    # ONLY this oid's fills (the unrelated-oid fill must be excluded); two fills → VWAP price.
    @client.expects(:user_fills_by_time)
           .with(user: "0xabc", start_time: 1781698875556)
           .returns(Honeymaker::Result::Success.new([
                                                       fill(oid: 123456789, px: "64000.0", sz: "0.00010"),
                                                       fill(oid: 123456789, px: "66000.0", sz: "0.00010"),
                                                       fill(oid: 999999999, px: "1.0", sz: "5.0") # other order
                                                     ]))

    result = @client.order_status(user: "0xabc", oid: 123456789)

    assert result.success?
    data = result.data
    assert_equal :closed, data[:status]
    assert_equal "@142", data[:coin]
    assert_equal :buy, data[:side]
    assert_equal BigDecimal("0.00020"), data[:amount]          # origSz, NOT remaining sz
    assert_equal BigDecimal("0.00020"), data[:amount_exec]     # origSz - sz, NOT the 5.0 unrelated fill
    assert_equal BigDecimal("13.0"), data[:quote_amount_exec]  # 6.4 + 6.6, unrelated fill excluded
    assert_equal BigDecimal("65000"), data[:price]             # 13.0 / 0.0002 volume-weighted
  end

  def test_order_status_filled_falls_back_to_limit_cost_when_no_matching_fill
    # userFills can age out / return nothing for THIS oid — a filled order must NEVER report
    # quote_amount_exec 0 (the job subtracts the quote delta from missed_quote_amount).
    order_body = order_status_body(status: "filled", sz: "0.0", orig_sz: "0.00018", limit_px: "64689.0")
    stub_connection(:post, order_body)
    @client.expects(:user_fills_by_time)
           .returns(Honeymaker::Result::Success.new([fill(oid: 111, px: "1.0", sz: "5.0")])) # no match

    result = @client.order_status(user: "0xabc", oid: 123456789)

    assert_equal :closed, result.data[:status]
    assert_equal BigDecimal("64689.0") * BigDecimal("0.00018"), result.data[:quote_amount_exec]
    assert_equal BigDecimal("64689.0"), result.data[:price]
  end

  def test_order_status_propagates_user_fills_failure_for_executed_order
    # A transient userFills failure must NOT degrade to an estimated cost — propagate it so the
    # consumer retries and the exact quote_amount_exec is eventually recorded.
    order_body = order_status_body(status: "filled", sz: "0.0", orig_sz: "0.00018")
    stub_connection(:post, order_body)
    @client.expects(:user_fills_by_time).returns(Honeymaker::Result::Failure.new("Net::ReadTimeout"))

    result = @client.order_status(user: "0xabc", oid: 123456789)

    assert result.failure?
    assert_includes result.errors, "Net::ReadTimeout"
  end

  def test_order_status_open_does_not_call_user_fills
    # Resting order: sz == origSz, nothing executed → no weight-20 userFills call.
    order_body = order_status_body(status: "open", sz: "0.00018", orig_sz: "0.00018")
    connection = stub
    connection.expects(:post).once.returns(stub(body: order_body)) # exactly one call — orderStatus only
    @client.instance_variable_set(:@connection, connection)
    @client.expects(:user_fills_by_time).never                     # gated on amount_exec > 0

    result = @client.order_status(user: "0xabc", oid: 123456789)

    assert result.success?
    assert_equal :open, result.data[:status]
    assert_equal BigDecimal("0"), result.data[:amount_exec]
    assert_equal BigDecimal("64689.0"), result.data[:price]    # falls back to the limit price
  end

  def test_order_status_partial_fill_is_open_with_executed_cost
    order_body = order_status_body(status: "open", sz: "0.00010", orig_sz: "0.00018",
                                   timestamp: 1781698875556, status_timestamp: 1781699999999)
    stub_connection(:post, order_body)
    @client.expects(:user_fills_by_time)
           .with(user: "0xabc", start_time: 1781698875556)
           .returns(Honeymaker::Result::Success.new([fill(oid: 123456789, px: "64500.0", sz: "0.00008")]))

    result = @client.order_status(user: "0xabc", oid: 123456789)

    assert result.success?
    assert_equal :open, result.data[:status]
    assert_equal BigDecimal("0.00008"), result.data[:amount_exec] # origSz - sz
    assert_equal BigDecimal("64500.0") * BigDecimal("0.00008"), result.data[:quote_amount_exec]
  end

  def test_order_status_margin_canceled_maps_to_cancelled
    stub_connection(:post, order_status_body(status: "marginCanceled", sz: "0.00018", orig_sz: "0.00018"))
    result = @client.order_status(user: "0xabc", oid: 1)
    assert_equal :cancelled, result.data[:status]
  end

  def test_order_status_scheduled_cancel_maps_to_cancelled
    stub_connection(:post, order_status_body(status: "scheduledCancel", sz: "0.00018", orig_sz: "0.00018"))
    result = @client.order_status(user: "0xabc", oid: 1)
    assert_equal :cancelled, result.data[:status]
  end

  def test_order_status_reduce_only_canceled_maps_to_cancelled
    # Suffix-aware /cancel/i covers the whole cancel family, not just the literals above.
    stub_connection(:post, order_status_body(status: "reduceOnlyCanceled", sz: "0.00018", orig_sz: "0.00018"))
    result = @client.order_status(user: "0xabc", oid: 1)
    assert_equal :cancelled, result.data[:status]
  end

  def test_order_status_rejected_maps_to_cancelled
    stub_connection(:post, order_status_body(status: "rejected", sz: "0.00018", orig_sz: "0.00018"))
    result = @client.order_status(user: "0xabc", oid: 1)
    assert_equal :cancelled, result.data[:status]
  end

  def test_order_status_unmapped_status_falls_back_to_unknown
    # A genuinely new Hyperliquid status must surface as :unknown (and be logged), never crash.
    stub_connection(:post, order_status_body(status: "someBrandNewStatus", sz: "0.00018", orig_sz: "0.00018"))
    result = @client.order_status(user: "0xabc", oid: 1)
    assert_equal :unknown, result.data[:status]
  end

  def test_order_status_triggered_maps_to_open
    # A triggered order has fired and become a live resting order → still open.
    stub_connection(:post, order_status_body(status: "triggered", sz: "0.00018", orig_sz: "0.00018"))
    result = @client.order_status(user: "0xabc", oid: 1)
    assert_equal :open, result.data[:status]
  end

  def test_order_status_unknown_oid_returns_not_found_signal
    stub_connection(:post, { "status" => "unknownOid" })
    result = @client.order_status(user: "0xabc", oid: 1)

    assert result.failure?
    assert_equal({ not_found: true }, result.data)
  end

  def test_open_orders
    stub_connection(:post, [])
    result = @client.open_orders(user: "0xabc")
    assert result.success?
  end

  def test_user_fills
    stub_connection(:post, [{ "oid" => 1, "side" => "B" }])
    result = @client.user_fills(user: "0xabc")
    assert result.success?
  end

  def test_user_fills_by_time
    stub_connection(:post, [{ "oid" => 1, "side" => "B" }])
    result = @client.user_fills_by_time(user: "0xabc", start_time: 1710936000000)
    assert result.success?
  end

  # == Raised trading errors keep their HTTP status ==
  #
  # Order placement goes through hyperliquid-rb, which raises instead of answering. Whether the
  # venue REFUSED the request or may have TAKEN it is the whole question for a caller deciding
  # between "record a rejected order" and "a human has to go and look" — and the status is the only
  # thing that answers it. It must survive the trip.

  # hyperliquid-rb's ClientError/ServerError shape. Rebuilt here because the gem is an optional
  # dependency this one does not carry.
  class RaisedWithStatus < StandardError
    attr_reader :status

    def initialize(message, status:)
      @status = status
      super(message)
    end
  end

  def test_order_reports_a_refusal_with_its_status
    @client.stubs(:exchange_client).raises(RaisedWithStatus.new("HTTP 429: rate limited", status: 429))

    result = @client.order(coin: "@142", is_buy: true, size: 1, limit_px: 100)

    assert result.failure?
    assert_equal 429, result.data[:status]
    assert_nil result.data[:client_error], "the venue answered — this is not an unknown outcome"
    assert_equal ["HTTP 429: rate limited"], result.errors
  end

  # 5xx stays 5xx: a gateway that may have passed the order on is exactly the case a caller must
  # keep treating as unresolved.
  def test_order_reports_a_gateway_failure_with_its_status
    @client.stubs(:exchange_client).raises(RaisedWithStatus.new("HTTP 502: bad gateway", status: 502))

    result = @client.order(coin: "@142", is_buy: true, size: 1, limit_px: 100)

    assert result.failure?
    assert_equal 502, result.data[:status]
  end

  def test_cancel_reports_a_refusal_with_its_status
    @client.stubs(:exchange_client).raises(RaisedWithStatus.new("HTTP 422: unknown oid", status: 422))

    result = @client.cancel(coin: "@142", oid: 1)

    assert result.failure?
    assert_equal 422, result.data[:status]
  end

  # Everything the venue did not answer is untouched: a signing crash inside the gem, a network
  # failure, a bug here. Those stay flagged as ours and unclassifiable.
  def test_order_leaves_a_statusless_error_classified_as_before
    @client.stubs(:exchange_client).raises(TypeError, "String can't be coerced into Float")

    result = @client.order(coin: "@142", is_buy: true, size: 1, limit_px: 100)

    assert result.failure?
    assert result.data[:client_error], "no status means no answer from the venue"
    assert_equal ["TypeError: String can't be coerced into Float"], result.errors
  end

  def test_order_wraps_an_accepted_placement
    @client.stubs(:exchange_client).returns(stub(order: { "status" => "ok" }))

    result = @client.order(coin: "@142", is_buy: true, size: 1, limit_px: 100)

    assert result.success?
    assert_equal({ "status" => "ok" }, result.data)
  end

  private

  def stub_connection(method, body)
    response = stub(body: body)
    connection = stub
    connection.stubs(method).returns(response)
    @client.instance_variable_set(:@connection, connection)
  end

  def order_status_body(status:, sz:, orig_sz:, coin: "@142", side: "B", limit_px: "64689.0",
                        oid: 123456789, timestamp: 1781698875556, status_timestamp: 1781699999999)
    {
      "status" => "order",
      "order" => {
        "order" => {
          "coin" => coin, "side" => side, "limitPx" => limit_px,
          "sz" => sz, "origSz" => orig_sz, "oid" => oid, "timestamp" => timestamp,
          "orderType" => "Limit", "tif" => "Gtc"
        },
        "status" => status,
        "statusTimestamp" => status_timestamp
      }
    }
  end

  def fill(oid:, px:, sz:, coin: "@142", side: "B")
    { "coin" => coin, "oid" => oid, "px" => px, "sz" => sz, "side" => side,
      "time" => 1781698875556, "fee" => "0.011", "tid" => 99 }
  end
end
