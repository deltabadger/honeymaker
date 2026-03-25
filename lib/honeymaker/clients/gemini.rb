# frozen_string_literal: true

module Honeymaker
  module Clients
    class Gemini < Client
      URL = "https://api.gemini.com"
      RATE_LIMITS = { default: 200, orders: 200 }.freeze

      def get_symbols
        get_public("/v1/symbols")
      end

      def get_symbol_details(symbol:)
        get_public("/v1/symbols/details/#{symbol}")
      end

      def get_ticker(symbol:)
        get_public("/v1/pubticker/#{symbol}")
      end

      def get_candles(symbol:, time_frame:)
        get_public("/v2/candles/#{symbol}/#{time_frame}")
      end

      def get_raw_balances
        post_signed("/v1/balances")
      end

      def get_balances
        result = get_raw_balances
        return result if result.failure?

        balances = {}
        Array(result.data).each do |balance|
          symbol = balance["currency"]&.upcase
          next unless symbol
          available = BigDecimal((balance["available"] || "0").to_s)
          amount = BigDecimal((balance["amount"] || "0").to_s)
          locked = amount - available
          next if available.zero? && locked.zero?
          balances[symbol] = { free: available, locked: locked }
        end

        Result::Success.new(balances)
      end

      def new_order(symbol:, amount:, price:, side:, type:, client_order_id: nil, options: [])
        result = post_signed("/v1/order/new", {
          symbol: symbol, amount: amount, price: price,
          side: side, type: type, client_order_id: client_order_id,
          options: options
        })
        return result if result.failure?

        raw = result.data
        Result::Success.new({ order_id: raw["order_id"].to_s, raw: raw })
      end

      def order_status(order_id:)
        result = post_signed("/v1/order/status", { order_id: order_id })
        return result if result.failure?

        raw = result.data
        Result::Success.new(normalize_order(raw["order_id"].to_s, raw))
      end

      def cancel_order(order_id:)
        post_signed("/v1/order/cancel", { order_id: order_id })
      end

      def get_my_trades(symbol: nil, limit_trades: nil, timestamp: nil)
        post_signed("/v1/mytrades", { symbol: symbol, limit_trades: limit_trades, timestamp: timestamp })
      end

      def get_transfers(timestamp: nil, limit_transfers: nil)
        post_signed("/v1/transfers", { timestamp: timestamp, limit_transfers: limit_transfers })
      end

      def withdraw(currency:, address:, amount:)
        post_signed("/v1/withdraw/#{currency}", { address: address, amount: amount })
      end

      # --- Staking ---

      def staking_history
        post_signed("/v1/staking/history")
      end

      def staking_rewards
        post_signed("/v1/staking/rewards")
      end

      def staking_balances
        post_signed("/v1/balances/staking")
      end

      private

      def normalize_order(order_id, raw)
        order_type = parse_order_type(raw["type"])
        side = raw["side"]&.downcase&.to_sym
        status = parse_gemini_order_status(raw)

        price = BigDecimal((raw["avg_execution_price"] || "0").to_s)
        price = BigDecimal((raw["price"] || "0").to_s) if price.zero?
        price = nil if price.zero?

        amount = BigDecimal((raw["original_amount"] || "0").to_s)
        amount_exec = BigDecimal((raw["executed_amount"] || "0").to_s)
        quote_amount_exec = price ? (amount_exec * price) : BigDecimal("0")

        {
          order_id: order_id, status: status, side: side, order_type: order_type,
          price: price, amount: amount, quote_amount: nil,
          amount_exec: amount_exec, quote_amount_exec: quote_amount_exec, raw: raw
        }
      end

      def parse_order_type(type)
        case type&.downcase
        when "exchange limit", "limit" then :limit
        when "market", "exchange market" then :market
        else :limit
        end
      end

      def parse_gemini_order_status(raw)
        if raw["is_cancelled"]
          :cancelled
        elsif raw["is_live"] && BigDecimal((raw["remaining_amount"] || "0").to_s).positive?
          :open
        elsif !raw["is_live"] && BigDecimal((raw["executed_amount"] || "0").to_s).positive?
          :closed
        else
          :unknown
        end
      end

      def validate_trading_credentials
        result = get_raw_balances
        return Result::Failure.new("Invalid trading credentials") if result.failure?
        result.data.is_a?(Array) ? Result::Success.new(true) : Result::Failure.new("Invalid trading credentials")
      end

      def validate_read_credentials
        validate_trading_credentials
      end

      def get_public(path, params = {})
        with_rescue do
          response = connection.get do |req|
            req.url path
            req.params = params.compact
          end
          response.body
        end
      end

      def post_signed(path, body = {})
        with_rescue do
          payload = body.compact.merge(request: path, nonce: timestamp_ms.to_s)
          encoded_payload = Base64.strict_encode64(payload.to_json)
          signature = hmac_sha256(@api_secret, encoded_payload)

          response = connection.post do |req|
            req.url path
            req.headers = {
              "X-GEMINI-APIKEY": @api_key,
              "X-GEMINI-PAYLOAD": encoded_payload,
              "X-GEMINI-SIGNATURE": signature,
              Accept: "application/json",
              "Content-Type": "text/plain"
            }
          end
          response.body
        end
      end
    end
  end
end
