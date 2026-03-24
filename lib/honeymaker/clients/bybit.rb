# frozen_string_literal: true

module Honeymaker
  module Clients
    class Bybit < Client
      URL = "https://api.bybit.com"
      RECV_WINDOW = "5000"

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

      def get_order(category:, order_id: nil, symbol: nil, order_link_id: nil)
        get_authenticated("/v5/order/realtime", {
          category: category, orderId: order_id, symbol: symbol, orderLinkId: order_link_id
        })
      end

      def create_order(category:, symbol:, side:, order_type:, qty:, price: nil,
                       time_in_force: nil, market_unit: nil, order_link_id: nil)
        post_authenticated("/v5/order/create", {
          category: category, symbol: symbol, side: side,
          orderType: order_type, qty: qty, price: price,
          timeInForce: time_in_force, marketUnit: market_unit,
          orderLinkId: order_link_id
        })
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

      private

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
