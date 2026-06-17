# frozen_string_literal: true

module Honeymaker
  module Clients
    class Hyperliquid < Client
      URL = "https://api.hyperliquid.xyz"
      RATE_LIMITS = { default: 200, orders: 200 }.freeze

      def initialize(api_key: nil, api_secret: nil, proxy: nil, logger: nil)
        super
      end

      def spot_meta
        post_info({ type: "spotMeta" })
      end

      def spot_meta_and_asset_ctxs
        post_info({ type: "spotMetaAndAssetCtxs" })
      end

      def spot_clearinghouse_state(user:)
        post_info({ type: "spotClearinghouseState", user: user })
      end

      def all_mids
        post_info({ type: "allMids" })
      end

      def spot_balances(user: nil)
        user ||= @api_key
        spot_clearinghouse_state(user: user)
      end

      def l2_book(coin:)
        post_info({ type: "l2Book", coin: coin })
      end

      def candles_snapshot(coin:, interval:, start_time:, end_time:)
        post_info({ type: "candleSnapshot", req: { coin: coin, interval: interval, startTime: start_time, endTime: end_time } })
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

      # Hyperliquid's orderStatus body is NESTED:
      #   { "status" => "order"|"unknownOid",
      #     "order"  => { "order" => { coin, side, limitPx, sz(remaining), origSz, oid, timestamp, ... },
      #                   "status" => <real order status>, "statusTimestamp" => ... } }
      # The real status/sizes live under order["order"]/order["status"] — NOT the top level — and the
      # body carries NO fills. So the ordered amount is origSz, executed is origSz - remaining sz, and the
      # exact cost comes from a bounded userFillsByTime (only fetched when something actually executed,
      # since userFillsByTime is API weight 20 vs orderStatus's weight 2).
      def order_status(user:, oid:)
        result = post_info({ type: "orderStatus", user: user, oid: oid })
        return result if result.failure?

        raw = result.data
        # A distinct not-found signal — aged-out orders are normal; the caller recovers fills / abandons.
        return Result::Failure.new("unknownOid", data: { not_found: true }) if raw["status"] == "unknownOid"

        wrapper = raw["order"] || {}
        order = wrapper["order"] || {}
        status_str = wrapper["status"]

        coin = order["coin"]
        side = order["side"] == "B" ? :buy : :sell
        limit_price = BigDecimal((order["limitPx"] || "0").to_s)
        ordered_size = BigDecimal((order["origSz"] || "0").to_s)
        remaining_size = BigDecimal((order["sz"] || "0").to_s)
        amount_exec = [ordered_size - remaining_size, BigDecimal("0")].max

        quote_amount_exec = BigDecimal("0")
        price = limit_price
        if amount_exec.positive?
          fills_result = order["timestamp"] ? user_fills_by_time(user: user, start_time: order["timestamp"]) : nil
          # A FAILED exact-cost lookup (timeout / rate-limit) is PROPAGATED so the consumer's typed-error
          # retry runs — never record an executed order with an estimated cost just because userFills
          # blipped (that would silently corrupt accounting and skip the retry).
          return fills_result if fills_result&.failure?

          matched = Array(fills_result&.data).select { |f| f["oid"].to_s == oid.to_s }
          matched_quote = matched.sum(BigDecimal("0")) { |f| BigDecimal(f["px"].to_s) * BigDecimal(f["sz"].to_s) }
          # userFills SUCCEEDED but has no matching fill (aged out of the window) → estimate from the
          # limit price so a filled order never reports quote_amount_exec 0. Only on success, never failure.
          quote_amount_exec = matched_quote.positive? ? matched_quote : (limit_price * amount_exec)
          price = quote_amount_exec / amount_exec
        end
        price = nil if price.nil? || price.zero?

        Result::Success.new({
          order_id: "#{coin}-#{oid}", coin: coin,
          status: parse_order_status(status_str), side: side, order_type: :limit,
          price: price, amount: ordered_size, quote_amount: nil,
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

      # --- Trading (requires hyperliquid-rb gem) ---

      def order(coin:, is_buy:, size:, limit_px:, order_type: { limit: { tif: "Gtc" } })
        with_rescue do
          exchange_client.order(coin, is_buy: is_buy, sz: size, limit_px: limit_px, order_type: order_type)
        end
      end

      def cancel(coin:, oid:)
        with_rescue do
          exchange_client.cancel(coin, oid)
        end
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

      # Suffix-aware so the whole Hyperliquid cancel family (marginCanceled, scheduledCancel,
      # reduceOnlyCanceled, siblingFilledCanceled, …) maps correctly. A triggered order has fired
      # and become a live resting order → :open. An unmapped status is logged, never swallowed.
      def parse_order_status(status)
        case status
        when "filled" then :closed
        when "open", "triggered" then :open
        else
          str = status.to_s
          if str.match?(/cancel/i) || str.match?(/reject/i)
            :cancelled
          else
            @logger&.warn("[honeymaker] Unmapped Hyperliquid order status: #{status.inspect}")
            :unknown
          end
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

      def exchange_client
        raise Error, "Trading requires api_secret (agent key)" unless @api_secret && !@api_secret.empty?
        @exchange ||= begin
          require "hyperliquid"
          ::Hyperliquid::Exchange.new(private_key: @api_secret)
        rescue LoadError
          raise Error, "Add 'hyperliquid-rb' to your Gemfile to use Hyperliquid trading"
        end
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
