# frozen_string_literal: true

module Honeymaker
  module Clients
    class Bitrue < Client
      URL = "https://openapi.bitrue.com"

      def exchange_information
        get_public("/api/v1/exchangeInfo")
      end

      def symbol_price_ticker(symbol: nil)
        get_public("/api/v1/ticker/price", { symbol: symbol })
      end

      def symbol_order_book_ticker(symbol: nil)
        get_public("/api/v1/ticker/bookTicker", { symbol: symbol })
      end

      def candlestick_data(symbol:, interval:, start_time: nil, end_time: nil, limit: 500)
        get_public("/api/v1/market/kline", {
          symbol: symbol, scale: interval, startTime: start_time,
          endTime: end_time, limit: limit
        })
      end

      def account_information(recv_window: 5000)
        get_signed("/api/v1/account", { recvWindow: recv_window })
      end

      def query_order(symbol:, order_id: nil, orig_client_order_id: nil, recv_window: 5000)
        get_signed("/api/v1/order", {
          symbol: symbol, orderId: order_id,
          origClientOrderId: orig_client_order_id, recvWindow: recv_window
        })
      end

      def new_order(symbol:, side:, type:, time_in_force: nil, quantity: nil, quote_order_qty: nil,
                    price: nil, new_client_order_id: nil, recv_window: 5000)
        post_signed("/api/v1/order", {
          symbol: symbol, side: side, type: type,
          timeInForce: time_in_force, quantity: quantity,
          quoteOrderQty: quote_order_qty, price: price,
          newClientOrderId: new_client_order_id, recvWindow: recv_window
        })
      end

      def cancel_order(symbol:, order_id: nil, orig_client_order_id: nil, recv_window: 5000)
        delete_signed("/api/v1/order", {
          symbol: symbol, orderId: order_id,
          origClientOrderId: orig_client_order_id, recvWindow: recv_window
        })
      end

      private

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
          response = connection.get do |req|
            req.url path
            req.headers = auth_headers
            req.params = params.compact.merge(timestamp: timestamp_ms)
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      def post_signed(path, params = {})
        with_rescue do
          response = connection.post do |req|
            req.url path
            req.headers = auth_headers
            req.params = params.compact.merge(timestamp: timestamp_ms)
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      def delete_signed(path, params = {})
        with_rescue do
          response = connection.delete do |req|
            req.url path
            req.headers = auth_headers
            req.params = params.compact.merge(timestamp: timestamp_ms)
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      def auth_headers
        { "X-MBX-APIKEY": @api_key, Accept: "application/json", "Content-Type": "application/json" }
      end

      def sign_params(params)
        return unless @api_secret
        query = Faraday::Utils.build_query(params)
        hmac_sha256(@api_secret, query)
      end
    end
  end
end
