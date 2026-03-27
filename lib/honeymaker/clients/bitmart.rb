# frozen_string_literal: true

module Honeymaker
  module Clients
    class BitMart < Client
      URL = "https://api-cloud.bitmart.com"
      RATE_LIMITS = { default: 100, orders: 200 }.freeze

      attr_reader :memo

      def initialize(api_key: nil, api_secret: nil, memo: nil, proxy: nil, logger: nil)
        super(api_key: api_key, api_secret: api_secret, proxy: proxy, logger: logger)
        @memo = memo
      end

      def get_symbols_details
        get_public("/spot/v1/symbols/details")
      end

      def get_currencies
        get_public("/account/v1/currencies")
      end

      def get_ticker(symbol: nil)
        get_public("/spot/quotation/v3/ticker", { symbol: symbol })
      end

      def get_depth(symbol:, limit: nil)
        get_public("/spot/quotation/v3/books", { symbol: symbol, limit: limit })
      end

      def get_klines(symbol:, step:, before: nil, after_time: nil, limit: nil)
        get_public("/spot/quotation/v3/lite-klines", {
          symbol: symbol, step: step, before: before, after: after_time, limit: limit
        })
      end

      def get_wallet
        get_signed("/spot/v1/wallet")
      end

      def get_balances
        result = get_wallet
        return result if result.failure?

        return Result::Failure.new("BitMart API error") unless result.data["code"] == 1000

        balances = {}
        (result.data.dig("data", "wallet") || []).each do |wallet|
          symbol = wallet["id"]
          free = BigDecimal((wallet["available"] || "0").to_s)
          locked = BigDecimal((wallet["frozen"] || "0").to_s)
          next if free.zero? && locked.zero?
          balances[symbol] = { free: free, locked: locked }
        end

        Result::Success.new(balances)
      end

      def submit_order(symbol:, side:, type:, size: nil, notional: nil, price: nil, client_order_id: nil)
        result = post_signed("/spot/v2/submit_order", {
          symbol: symbol, side: side, type: type,
          size: size, notional: notional, price: price,
          client_order_id: client_order_id
        })
        return result if result.failure?
        return Result::Failure.new("BitMart API error") unless result.data["code"] == 1000

        order_id = result.data.dig("data", "order_id")
        Result::Success.new({ order_id: order_id.to_s, raw: result.data })
      end

      def get_order(order_id:)
        result = post_signed("/spot/v2/order_detail", { orderId: order_id })
        return result if result.failure?
        return Result::Failure.new("BitMart API error") unless result.data["code"] == 1000

        raw = result.data["data"]
        return Result::Failure.new("Order not found") unless raw

        Result::Success.new(normalize_order(order_id.to_s, raw))
      end

      def cancel_order(symbol:, order_id: nil, client_order_id: nil)
        post_signed("/spot/v3/cancel_order", {
          symbol: symbol, order_id: order_id, client_order_id: client_order_id
        })
      end

      def get_trades(symbol:, order_mode: nil, start_time: nil, end_time: nil, limit: nil, recv_window: nil)
        get_signed("/spot/v2/trades", {
          symbol: symbol, orderMode: order_mode,
          startTime: start_time, endTime: end_time, N: limit, recvWindow: recv_window
        })
      end

      def deposit_list(currency: nil, n: nil, status: nil)
        get_signed("/account/v1/deposit-withdraw/detail", {
          currency: currency, N: n, type: "deposit", operation_type: "deposit", status: status
        })
      end

      def withdraw_list(currency: nil, n: nil, status: nil)
        get_signed("/account/v1/deposit-withdraw/detail", {
          currency: currency, N: n, type: "withdraw", operation_type: "withdraw", status: status
        })
      end

      def get_withdraw_addresses
        get_signed("/account/v1/withdraw/address/list")
      end

      def withdraw(currency:, amount:, address:, address_memo: nil, destination: nil)
        post_signed("/account/v1/withdraw/apply", {
          currency: currency, amount: amount,
          destination: destination || "To Digital Address",
          address: address, address_memo: address_memo
        })
      end

      # --- Margin ---

      def margin_borrow_records(symbol: nil, borrow_id: nil, start_time: nil, end_time: nil, n: nil)
        get_signed("/spot/v1/margin/isolated/borrow_record", {
          symbol: symbol, borrow_id: borrow_id, start_time: start_time, end_time: end_time, N: n
        })
      end

      def margin_repay_records(symbol: nil, repay_id: nil, currency: nil, start_time: nil, end_time: nil, n: nil)
        get_signed("/spot/v1/margin/isolated/repay_record", {
          symbol: symbol, repay_id: repay_id, currency: currency, start_time: start_time, end_time: end_time, N: n
        })
      end

      # --- Futures ---

      def futures_transaction_history(start_time: nil, end_time: nil, page_num: nil, page_size: nil, flow_type: nil)
        get_signed("/contract/private/transaction-history", {
          start_time: start_time, end_time: end_time,
          page_num: page_num, page_size: page_size, flow_type: flow_type
        })
      end

      def futures_trades(symbol:, start_time: nil, end_time: nil, page_num: nil, page_size: nil)
        get_signed("/contract/private/trades", {
          symbol: symbol, start_time: start_time, end_time: end_time,
          page_num: page_num, page_size: page_size
        })
      end

      private

      def normalize_order(order_id, raw)
        order_type = parse_order_type(raw["type"])
        side = raw["side"]&.downcase&.to_sym
        status = parse_order_status(raw["status"])

        amount = BigDecimal((raw["size"] || "0").to_s)
        amount = nil if amount.zero?
        quote_amount = raw["notional"] ? BigDecimal(raw["notional"].to_s) : nil
        quote_amount = nil if quote_amount&.zero?

        amount_exec = BigDecimal((raw["filled_size"] || "0").to_s)
        quote_amount_exec = BigDecimal((raw["filled_notional"] || "0").to_s)
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
        when "market" then :market
        when "limit" then :limit
        else :unknown
        end
      end

      def parse_order_status(status)
        case status
        when "new", "partially_filled" then :open
        when "filled" then :closed
        when "canceled", "expired", "partially_canceled" then :cancelled
        when "rejected", "failed" then :failed
        else :unknown
        end
      end

      def validate_trading_credentials
        result = get_wallet
        return Result::Failure.new("Invalid trading credentials") if result.failure?
        result.data["code"] == 1000 ? Result::Success.new(true) : Result::Failure.new("Invalid trading credentials")
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
          ts = timestamp_ms.to_s
          query_string = params.compact.empty? ? "" : "?#{Faraday::Utils.build_query(params.compact)}"
          pre_sign = "#{ts}##{@memo}##{query_string}"

          response = connection.get do |req|
            req.url path
            req.headers = signed_headers(ts, pre_sign)
            req.params = params.compact
          end
          response.body
        end
      end

      def post_signed(path, body = {})
        with_rescue do
          ts = timestamp_ms.to_s
          body_json = body.compact.to_json
          pre_sign = "#{ts}##{@memo}##{body_json}"

          response = connection.post do |req|
            req.url path
            req.headers = signed_headers(ts, pre_sign)
            req.body = body.compact
          end
          response.body
        end
      end

      def signed_headers(timestamp, pre_sign)
        signature = hmac_sha256(@api_secret, pre_sign)
        {
          "X-BM-KEY": @api_key,
          "X-BM-SIGN": signature,
          "X-BM-TIMESTAMP": timestamp,
          Accept: "application/json",
          "Content-Type": "application/json"
        }
      end
    end
  end
end
