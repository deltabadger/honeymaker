# frozen_string_literal: true

module Honeymaker
  module Clients
    class Hyperliquid < Client
      URL = "https://api.hyperliquid.xyz"
      RATE_LIMITS = { default: 200, orders: 200 }.freeze

      def spot_meta
        post_info({ type: "spotMeta" })
      end

      def spot_meta_and_asset_ctxs
        post_info({ type: "spotMetaAndAssetCtxs" })
      end

      def spot_clearinghouse_state(user:)
        post_info({ type: "spotClearinghouseState", user: user })
      end

      def get_balances(user: nil)
        user ||= @api_key
        result = spot_clearinghouse_state(user: user)
        return result if result.failure?

        balances = {}
        (result.data["balances"] || []).each do |balance|
          symbol = balance["coin"]
          total = BigDecimal((balance["total"] || "0").to_s)
          hold = BigDecimal((balance["hold"] || "0").to_s)
          free = total - hold
          next if free.zero? && hold.zero?
          balances[symbol] = { free: free, locked: hold }
        end

        Result::Success.new(balances)
      end

      def order_status(user:, oid:)
        result = post_info({ type: "orderStatus", user: user, oid: oid })
        return result if result.failure?

        raw = result.data
        order = raw["order"] || {}
        fills = raw["fills"] || []
        status_str = raw["status"]

        coin = order["coin"]
        side = order["side"] == "B" ? :buy : :sell
        limit_price = BigDecimal((order["limitPx"] || "0").to_s)
        ordered_size = BigDecimal((order["sz"] || "0").to_s)

        amount_exec = fills.sum { |f| BigDecimal(f["sz"].to_s) }
        quote_amount_exec = fills.sum { |f| BigDecimal(f["px"].to_s) * BigDecimal(f["sz"].to_s) }
        avg_price = amount_exec.positive? ? (quote_amount_exec / amount_exec) : limit_price
        avg_price = nil if avg_price.zero?

        status = parse_order_status(status_str)

        Result::Success.new({
          order_id: "#{coin}-#{oid}",
          status: status, side: side, order_type: :limit,
          price: avg_price, amount: ordered_size, quote_amount: nil,
          amount_exec: amount_exec, quote_amount_exec: quote_amount_exec, raw: raw
        })
      end

      def open_orders(user:)
        post_info({ type: "openOrders", user: user })
      end

      def user_fills(user:, start_time: nil, end_time: nil)
        body = { type: "userFills", user: user }
        body[:startTime] = start_time if start_time
        body[:endTime] = end_time if end_time
        post_info(body)
      end

      def user_fills_by_time(user:, start_time:, end_time: nil)
        body = { type: "userFillsByTime", user: user, startTime: start_time }
        body[:endTime] = end_time if end_time
        post_info(body)
      end

      # --- Futures ---

      def user_funding(user:, start_time:, end_time: nil)
        body = { type: "userFunding", user: user, startTime: start_time }
        body[:endTime] = end_time if end_time
        post_info(body)
      end

      def user_non_funding_ledger_updates(user:, start_time:, end_time: nil)
        body = { type: "userNonFundingLedgerUpdates", user: user, startTime: start_time }
        body[:endTime] = end_time if end_time
        post_info(body)
      end

      private

      def parse_order_status(status)
        case status
        when "open", "marginCanceled" then :open
        when "filled" then :closed
        when "canceled", "triggered", "rejected" then :cancelled
        when "unknownOid" then :unknown
        else :unknown
        end
      end

      def validate_trading_credentials
        return Result::Failure.new("No wallet address provided") unless @api_key
        result = open_orders(user: @api_key)
        result.success? ? Result::Success.new(true) : Result::Failure.new("Invalid credentials")
      end

      def validate_read_credentials
        validate_trading_credentials
      end

      def post_info(body)
        with_rescue do
          response = connection.post do |req|
            req.url "/info"
            req.headers = { Accept: "application/json", "Content-Type": "application/json" }
            req.body = body.to_json
          end
          response.body
        end
      end
    end
  end
end
