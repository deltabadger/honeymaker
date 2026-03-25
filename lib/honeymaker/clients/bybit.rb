# frozen_string_literal: true

module Honeymaker
  module Clients
    class Bybit < Client
      URL = "https://api.bybit.com"
      RECV_WINDOW = "5000"
      RATE_LIMITS = { default: 100, orders: 200 }.freeze

      def get_coin_query_info
        get_authenticated("/v5/asset/coin/query-info")
      end

      def instruments_info(category:, symbol: nil, status: nil, base_coin: nil, limit: nil, cursor: nil)
        get_public("/v5/market/instruments-info", {
          category: category, symbol: symbol, status: status,
          baseCoin: base_coin, limit: limit, cursor: cursor
        })
      end

      def tickers(category:, symbol: nil, base_coin: nil, exp_date: nil)
        get_public("/v5/market/tickers", {
          category: category, symbol: symbol, baseCoin: base_coin, expDate: exp_date
        })
      end

      def orderbook(category:, symbol:, limit: nil)
        get_public("/v5/market/orderbook", { category: category, symbol: symbol, limit: limit })
      end

      def kline(category:, symbol:, interval:, start: nil, end_time: nil, limit: nil)
        get_public("/v5/market/kline", {
          category: category, symbol: symbol, interval: interval,
          start: start, end: end_time, limit: limit
        })
      end

      def wallet_balance(account_type:, coin: nil)
        get_authenticated("/v5/account/wallet-balance", { accountType: account_type, coin: coin })
      end

      def get_balances(account_type: "UNIFIED")
        result = wallet_balance(account_type: account_type)
        return result if result.failure?

        return Result::Failure.new(result.data["retMsg"]) unless result.data["retCode"]&.zero?

        balances = {}
        accounts = result.data.dig("result", "list") || []
        accounts.each do |account|
          (account["coin"] || []).each do |coin|
            symbol = coin["coin"]
            free = BigDecimal((coin["availableToWithdraw"] || "0").to_s)
            locked = BigDecimal((coin["locked"] || "0").to_s)
            next if free.zero? && locked.zero?
            balances[symbol] = { free: free, locked: locked }
          end
        end

        Result::Success.new(balances)
      end

      def get_order(category:, order_id: nil, symbol: nil, order_link_id: nil)
        result = get_authenticated("/v5/order/realtime", {
          category: category, orderId: order_id, symbol: symbol, orderLinkId: order_link_id
        })
        return result if result.failure?
        return Result::Failure.new(result.data["retMsg"]) unless result.data["retCode"]&.zero?

        order_list = result.data.dig("result", "list") || []
        raw = order_list.first
        return Result::Failure.new("Order not found") unless raw

        Result::Success.new(normalize_order(raw["orderId"], raw))
      end

      def create_order(category:, symbol:, side:, order_type:, qty:, price: nil,
                       time_in_force: nil, market_unit: nil, order_link_id: nil)
        result = post_authenticated("/v5/order/create", {
          category: category, symbol: symbol, side: side,
          orderType: order_type, qty: qty, price: price,
          timeInForce: time_in_force, marketUnit: market_unit,
          orderLinkId: order_link_id
        })
        return result if result.failure?
        return Result::Failure.new(result.data["retMsg"]) unless result.data["retCode"]&.zero?

        order_id = result.data.dig("result", "orderId")
        Result::Success.new({ order_id: order_id, raw: result.data })
      end

      def cancel_order(category:, symbol:, order_id: nil, order_link_id: nil)
        post_authenticated("/v5/order/cancel", {
          category: category, symbol: symbol,
          orderId: order_id, orderLinkId: order_link_id
        })
      end

      def transaction_log(account_type: nil, category: nil, currency: nil, type: nil, start_time: nil, end_time: nil, limit: nil, cursor: nil)
        get_authenticated("/v5/account/transaction-log", {
          accountType: account_type, category: category, currency: currency, type: type,
          startTime: start_time, endTime: end_time, limit: limit, cursor: cursor
        })
      end

      def execution_list(category:, symbol: nil, order_id: nil, start_time: nil, end_time: nil, limit: nil, cursor: nil)
        get_authenticated("/v5/execution/list", {
          category: category, symbol: symbol, orderId: order_id,
          startTime: start_time, endTime: end_time, limit: limit, cursor: cursor
        })
      end

      def deposit_records(coin: nil, start_time: nil, end_time: nil, limit: nil, cursor: nil)
        get_authenticated("/v5/asset/deposit/query-record", {
          coin: coin, startTime: start_time, endTime: end_time, limit: limit, cursor: cursor
        })
      end

      def withdraw_records(coin: nil, start_time: nil, end_time: nil, limit: nil, cursor: nil, withdraw_type: nil)
        get_authenticated("/v5/asset/withdraw/query-record", {
          coin: coin, startTime: start_time, endTime: end_time,
          limit: limit, cursor: cursor, withdrawType: withdraw_type
        })
      end

      def withdraw(coin:, chain:, address:, amount:, tag: nil, force_chain: nil)
        post_authenticated("/v5/asset/withdraw/create", {
          coin: coin, chain: chain, address: address, amount: amount,
          tag: tag, forceChain: force_chain, timestamp: timestamp_ms
        })
      end

      # --- Margin ---

      def borrow_history(currency: nil, start_time: nil, end_time: nil, limit: nil, cursor: nil)
        get_authenticated("/v5/account/borrow-history", {
          currency: currency, startTime: start_time, endTime: end_time, limit: limit, cursor: cursor
        })
      end

      def spot_margin_repay_history(start_time: nil, end_time: nil, coin: nil, limit: nil, cursor: nil)
        get_authenticated("/v5/spot-cross-margin-trade/repay-history", {
          startTime: start_time, endTime: end_time, coin: coin, limit: limit, cursor: cursor
        })
      end

      # --- Futures ---

      def delivery_records(category:, symbol: nil, exp_date: nil, limit: nil, cursor: nil)
        get_authenticated("/v5/asset/delivery-record", {
          category: category, symbol: symbol, expDate: exp_date, limit: limit, cursor: cursor
        })
      end

      def settlement_records(category:, symbol: nil, limit: nil, cursor: nil)
        get_authenticated("/v5/asset/settlement-record", {
          category: category, symbol: symbol, limit: limit, cursor: cursor
        })
      end

      # --- Earn ---

      def earn_order_records(order_id: nil, order_type: nil, start_time: nil, end_time: nil, limit: nil, cursor: nil)
        get_authenticated("/v5/earn/order-records", {
          orderId: order_id, orderType: order_type,
          startTime: start_time, endTime: end_time, limit: limit, cursor: cursor
        })
      end

      def earn_yield_history(product_id: nil, start_time: nil, end_time: nil, limit: nil, cursor: nil)
        get_authenticated("/v5/earn/yield-history", {
          productId: product_id, startTime: start_time, endTime: end_time, limit: limit, cursor: cursor
        })
      end

      private

      def normalize_order(order_id, raw)
        order_type = parse_order_type(raw["orderType"])
        side = raw["side"]&.downcase&.to_sym
        status = parse_order_status(raw["orderStatus"])

        price = BigDecimal((raw["avgPrice"] || "0").to_s)
        price = BigDecimal((raw["price"] || "0").to_s) if price.zero?
        price = nil if price.zero?

        amount = BigDecimal((raw["qty"] || "0").to_s)
        amount = nil if amount.zero?
        amount_exec = BigDecimal((raw["cumExecQty"] || "0").to_s)
        quote_amount_exec = BigDecimal((raw["cumExecValue"] || "0").to_s)

        {
          order_id: order_id, status: status, side: side, order_type: order_type,
          price: price, amount: amount, quote_amount: nil,
          amount_exec: amount_exec, quote_amount_exec: quote_amount_exec, raw: raw
        }
      end

      def parse_order_type(type)
        case type
        when "Market" then :market
        when "Limit" then :limit
        else :unknown
        end
      end

      def parse_order_status(status)
        case status
        when "Created", "Untriggered" then :unknown
        when "New", "PartiallyFilled", "PartiallyFilledCanceled" then :open
        when "Filled" then :closed
        when "Cancelled", "Expired", "Deactivated" then :cancelled
        when "Rejected" then :failed
        else :unknown
        end
      end

      def validate_trading_credentials
        result = wallet_balance(account_type: "UNIFIED")
        return Result::Failure.new("Invalid trading credentials") if result.failure?
        result.data["retCode"]&.zero? ? Result::Success.new(true) : Result::Failure.new("Invalid trading credentials")
      end

      def validate_read_credentials
        validate_trading_credentials
      end

      def get_public(path, params = {})
        with_rescue do
          response = connection.get do |req|
            req.url path
            req.headers = unauthenticated_headers
            req.params = params.compact
          end
          response.body
        end
      end

      def get_authenticated(path, params = {})
        with_rescue do
          params = params.compact
          response = connection.get do |req|
            req.url path
            req.headers = signed_headers("GET", params)
            req.params = params
          end
          response.body
        end
      end

      def post_authenticated(path, body = {})
        with_rescue do
          body = body.compact
          response = connection.post do |req|
            req.url path
            req.headers = signed_headers("POST", body)
            req.body = body
          end
          response.body
        end
      end

      def unauthenticated_headers
        { Accept: "application/json", "Content-Type": "application/json" }
      end

      def signed_headers(method, params_or_body)
        return unauthenticated_headers unless authenticated?

        ts = timestamp_ms
        payload = if method == "GET"
                    query_string = Faraday::Utils.build_query(params_or_body)
                    "#{ts}#{@api_key}#{RECV_WINDOW}#{query_string}"
                  else
                    "#{ts}#{@api_key}#{RECV_WINDOW}#{params_or_body.to_json}"
                  end

        signature = hmac_sha256(@api_secret, payload)

        {
          "X-BAPI-API-KEY": @api_key,
          "X-BAPI-SIGN": signature,
          "X-BAPI-TIMESTAMP": ts.to_s,
          "X-BAPI-RECV-WINDOW": RECV_WINDOW,
          Accept: "application/json",
          "Content-Type": "application/json"
        }
      end
    end
  end
end
