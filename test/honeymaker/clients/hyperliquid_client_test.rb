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

  def test_order_status
    stub_connection(:post, { "status" => "filled" })
    result = @client.order_status(user: "0xabc", oid: 123)
    assert result.success?
  end

  def test_open_orders
    stub_connection(:post, [])
    result = @client.open_orders(user: "0xabc")
    assert result.success?
  end

  private

  def stub_connection(method, body)
    response = stub(body: body)
    connection = stub
    connection.stubs(method).returns(response)
    @client.instance_variable_set(:@connection, connection)
  end
end
