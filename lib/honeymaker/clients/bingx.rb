# frozen_string_literal: true

module Honeymaker
  module Clients
    class BingX < Client
      URL = "https://open-api.bingx.com"
      RATE_LIMITS = { default: 100, orders: 200 }.freeze

      def get_symbols
        get_public("/openApi/spot/v1/common/symbols")
      end

      def get_ticker(symbol: nil)
        get_public("/openApi/spot/v2/market/ticker", { symbol: symbol })
      end

      def get_depth(symbol:, limit: nil)
        get_public("/openApi/spot/v1/market/depth", { symbol: symbol, limit: limit })
      end

      def get_klines(symbol:, interval:, start_time: nil, end_time: nil, limit: nil)
        get_public("/openApi/spot/v1/market/kline", {
          symbol: symbol, interval: interval,
          startTime: start_time, endTime: end_time, limit: limit
        })
      end

      def get_raw_balances
        get_signed("/openApi/spot/v1/account/balance")
      end

      def get_balances
        result = get_raw_balances
        return result if result.failure?

        balances = {}
        raw_balances = result.data.dig("data", "balances") || []
        raw_balances.each do |balance|
          symbol = balance["asset"]
          free = BigDecimal((balance["free"] || "0").to_s)
          locked = BigDecimal((balance["locked"] || "0").to_s)
          next if free.zero? && locked.zero?
          balances[symbol] = { free: free, locked: locked }
        end

        Result::Success.new(balances)
      end

      def place_order(symbol:, side:, type:, quantity: nil, quote_order_qty: nil, price: nil,
                      time_in_force: nil, client_order_id: nil)
        result = post_signed("/openApi/spot/v1/trade/order", {
          symbol: symbol, side: side, type: type,
          quantity: quantity, quoteOrderQty: quote_order_qty,
          price: price, timeInForce: time_in_force,
          newClientOrderId: client_order_id
        })
        return result if result.failure?

        raw = result.data
        order_id = raw.dig("data", "orderId") || raw.dig("data", "data", "orderId")
        Result::Success.new({ order_id: "#{symbol}-#{order_id}", raw: raw })
      end

      def get_order(symbol:, order_id: nil, client_order_id: nil)
        result = get_signed("/openApi/spot/v1/trade/query", {
          symbol: symbol, orderId: order_id, clientOrderID: client_order_id
        })
        return result if result.failure?

        raw = result.data.is_a?(Hash) && result.data.key?("data") ? result.data["data"] : result.data
        Result::Success.new(normalize_order("#{symbol}-#{raw['orderId']}", raw))
      end

      def cancel_order(symbol:, order_id: nil, client_order_id: nil)
        post_signed("/openApi/spot/v1/trade/cancel", {
          symbol: symbol, orderId: order_id, clientOrderID: client_order_id
        })
      end

      def get_all_coins_info
        get_signed("/openApi/wallets/v1/capital/config/getall")
      end

      def get_trade_fills(symbol: nil, order_id: nil, start_time: nil, end_time: nil, from_id: nil, limit: nil)
        get_signed("/openApi/spot/v1/trade/fills", {
          symbol: symbol, orderId: order_id,
          startTime: start_time, endTime: end_time, fromId: from_id, limit: limit
        })
      end

      def deposit_history(coin: nil, status: nil, start_time: nil, end_time: nil, offset: nil, limit: nil)
        get_signed("/openApi/wallets/v1/capital/deposit/hisrec", {
          coin: coin, status: status,
          startTime: start_time, endTime: end_time, offset: offset, limit: limit
        })
      end

      def withdraw_history(coin: nil, status: nil, start_time: nil, end_time: nil, offset: nil, limit: nil, id: nil)
        get_signed("/openApi/wallets/v1/capital/withdraw/history", {
          coin: coin, status: status,
          startTime: start_time, endTime: end_time, offset: offset, limit: limit, id: id
        })
      end

      def withdraw(coin:, address:, amount:, network: nil, wallet_type: nil, tag: nil)
        post_signed("/openApi/wallets/v1/capital/withdraw/apply", {
          coin: coin, address: address, amount: amount,
          network: network, walletType: wallet_type, tag: tag
        })
      end

      # --- Futures ---

      def futures_income(symbol: nil, income_type: nil, start_time: nil, end_time: nil, limit: nil)
        with_rescue do
          params = {
            symbol: symbol, incomeType: income_type,
            startTime: start_time, endTime: end_time, limit: limit,
            timestamp: timestamp_ms
          }.compact
          params[:signature] = hmac_sha256(@api_secret, Faraday::Utils.build_query(params))

          response = futures_connection.get do |req|
            req.url "/openApi/swap/v2/user/income"
            req.headers = { "X-BX-APIKEY": @api_key }
            req.params = params
          end
          response.body
        end
      end

      private

      def normalize_order(order_id, raw)
        order_type = parse_order_type(raw["type"])
        side = raw["side"]&.downcase&.to_sym
        status = parse_order_status(raw["status"])

        amount = BigDecimal((raw["origQty"] || "0").to_s)
        amount = nil if amount.zero?
        quote_amount = raw["origQuoteOrderQty"] ? BigDecimal(raw["origQuoteOrderQty"].to_s) : nil
        quote_amount = nil if quote_amount&.zero?

        amount_exec = BigDecimal((raw["executedQty"] || "0").to_s)
        quote_amount_exec = BigDecimal((raw["cummulativeQuoteQty"] || "0").to_s)
        quote_amount_exec = nil if quote_amount_exec.negative?

        price = BigDecimal((raw["price"] || "0").to_s)
        if price.zero? && quote_amount_exec&.positive? && amount_exec.positive?
          price = quote_amount_exec / amount_exec
        end
        price = nil if price.zero?

        {
          order_id: order_id, status: status, side: side, order_type: order_type,
          price: price, amount: amount, quote_amount: quote_amount,
          amount_exec: amount_exec, quote_amount_exec: quote_amount_exec, raw: raw
        }
      end

      def parse_order_type(type)
        case type
        when "MARKET" then :market
        when "LIMIT" then :limit
        else :unknown
        end
      end

      def parse_order_status(status)
        case status
        when "NEW", "PARTIALLY_FILLED", "PENDING" then :open
        when "FILLED" then :closed
        when "CANCELED", "EXPIRED" then :cancelled
        when "REJECTED", "FAILED" then :failed
        else :unknown
        end
      end

      def validate_trading_credentials
        result = get_raw_balances
        return Result::Failure.new("Invalid trading credentials") if result.failure?
        result.data["code"]&.to_i&.zero? ? Result::Success.new(true) : Result::Failure.new("Invalid trading credentials")
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

      def get_signed(path, params = {})
        with_rescue do
          params = params.compact.merge(timestamp: timestamp_ms)
          params[:signature] = hmac_sha256(@api_secret, Faraday::Utils.build_query(params))

          response = connection.get do |req|
            req.url path
            req.headers = { "X-BX-APIKEY": @api_key }
            req.params = params
          end
          response.body
        end
      end

      def post_signed(path, params = {})
        with_rescue do
          params = params.compact.merge(timestamp: timestamp_ms)
          params[:signature] = hmac_sha256(@api_secret, Faraday::Utils.build_query(params))

          response = connection.post do |req|
            req.url path
            req.headers = { "X-BX-APIKEY": @api_key, "Content-Type": "application/json" }
            req.params = params
          end
          response.body
        end
      end

      def futures_connection
        @futures_connection ||= build_client_connection("https://open-api.bingx.com", content_type_match: //)
      end

      def connection
        @connection ||= build_client_connection(URL, content_type_match: //)
      end
    end
  end
end
