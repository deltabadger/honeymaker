# frozen_string_literal: true

module Honeymaker
  module Clients
    class Bitvavo < Client
      URL = "https://api.bitvavo.com"
      ACCESS_WINDOW = "10000"

      def get_assets
        get_public("/v2/assets")
      end

      def get_markets(market: nil)
        get_public("/v2/markets", { market: market })
      end

      def get_ticker_price(market: nil)
        get_public("/v2/ticker/price", { market: market })
      end

      def get_ticker_book(market: nil)
        get_public("/v2/ticker/book", { market: market })
      end

      def get_candles(market:, interval:, start_time: nil, end_time: nil, limit: nil)
        get_public("/v2/#{market}/candles", {
          interval: interval, start: start_time, end: end_time, limit: limit
        })
      end

      def get_balance(symbol: nil)
        get_signed("/v2/balance", { symbol: symbol })
      end

      def place_order(market:, side:, order_type:, amount: nil, amount_quote: nil, price: nil,
                      time_in_force: nil, client_order_id: nil)
        post_signed("/v2/order", {
          market: market, side: side, orderType: order_type,
          amount: amount, amountQuote: amount_quote, price: price,
          timeInForce: time_in_force, clientOrderId: client_order_id
        })
      end

      def get_order(market:, order_id:)
        get_signed("/v2/order", { market: market, orderId: order_id })
      end

      def cancel_order(market:, order_id:)
        delete_signed("/v2/order", { market: market, orderId: order_id })
      end

      def get_trades(market:, limit: nil, start_time: nil, end_time: nil, trade_id_from: nil, trade_id_to: nil)
        get_signed("/v2/trades", {
          market: market, limit: limit, start: start_time, end: end_time,
          tradeIdFrom: trade_id_from, tradeIdTo: trade_id_to
        })
      end

      def get_deposit_history(symbol: nil, limit: nil, start_time: nil, end_time: nil)
        get_signed("/v2/deposit", { symbol: symbol, limit: limit, start: start_time, end: end_time })
      end

      def get_withdrawal_history(symbol: nil, limit: nil, start_time: nil, end_time: nil)
        get_signed("/v2/withdrawal", { symbol: symbol, limit: limit, start: start_time, end: end_time })
      end

      def withdraw(symbol:, amount:, address:, payment_id: nil)
        post_signed("/v2/withdrawal", {
          symbol: symbol, amount: amount, address: address, paymentId: payment_id
        })
      end

      private

      def validate_trading_credentials
        result = get_balance
        result.success? ? Result::Success.new(true) : Result::Failure.new("Invalid trading credentials")
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

      def get_signed(path, params = {})
        with_rescue do
          params = params.compact
          query_string = params.any? ? "?#{Faraday::Utils.build_query(params)}" : ""
          ts = timestamp_ms.to_s
          payload = "#{ts}GET#{path}#{query_string}"

          response = connection.get do |req|
            req.url path
            req.headers = signed_headers(ts, payload)
            req.params = params
          end
          response.body
        end
      end

      def post_signed(path, body = {})
        with_rescue do
          body = body.compact
          body_string = body.to_json
          ts = timestamp_ms.to_s
          payload = "#{ts}POST#{path}#{body_string}"

          response = connection.post do |req|
            req.url path
            req.headers = signed_headers(ts, payload)
            req.body = body
          end
          response.body
        end
      end

      def delete_signed(path, params = {})
        with_rescue do
          params = params.compact
          query_string = params.any? ? "?#{Faraday::Utils.build_query(params)}" : ""
          ts = timestamp_ms.to_s
          payload = "#{ts}DELETE#{path}#{query_string}"

          response = connection.delete do |req|
            req.url path
            req.headers = signed_headers(ts, payload)
            req.params = params
          end
          response.body
        end
      end

      def unauthenticated_headers
        { Accept: "application/json", "Content-Type": "application/json" }
      end

      def signed_headers(timestamp, payload)
        signature = hmac_sha256(@api_secret, payload)
        {
          "BITVAVO-ACCESS-KEY": @api_key,
          "BITVAVO-ACCESS-SIGNATURE": signature,
          "BITVAVO-ACCESS-TIMESTAMP": timestamp,
          "BITVAVO-ACCESS-WINDOW": ACCESS_WINDOW,
          Accept: "application/json",
          "Content-Type": "application/json"
        }
      end
    end
  end
end
