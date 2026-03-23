# frozen_string_literal: true

module Honeymaker
  module Clients
    class BingX < Client
      URL = "https://open-api.bingx.com"

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

      def get_balances
        get_signed("/openApi/spot/v1/account/balance")
      end

      def place_order(symbol:, side:, type:, quantity: nil, quote_order_qty: nil, price: nil,
                      time_in_force: nil, client_order_id: nil)
        post_signed("/openApi/spot/v1/trade/order", {
          symbol: symbol, side: side, type: type,
          quantity: quantity, quoteOrderQty: quote_order_qty,
          price: price, timeInForce: time_in_force,
          newClientOrderId: client_order_id
        })
      end

      def get_order(symbol:, order_id: nil, client_order_id: nil)
        get_signed("/openApi/spot/v1/trade/query", {
          symbol: symbol, orderId: order_id, clientOrderID: client_order_id
        })
      end

      def cancel_order(symbol:, order_id: nil, client_order_id: nil)
        post_signed("/openApi/spot/v1/trade/cancel", {
          symbol: symbol, orderId: order_id, clientOrderID: client_order_id
        })
      end

      def withdraw(coin:, address:, amount:, network: nil, wallet_type: nil, tag: nil)
        post_signed("/openApi/wallets/v1/capital/withdraw/apply", {
          coin: coin, address: address, amount: amount,
          network: network, walletType: wallet_type, tag: tag
        })
      end

      private

      def validate_trading_credentials
        result = get_balances
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

      def connection
        @connection ||= build_client_connection(URL, content_type_match: //)
      end
    end
  end
end
