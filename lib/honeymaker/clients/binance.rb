# frozen_string_literal: true

module Honeymaker
  module Clients
    class Binance < Client
      URL = "https://api.binance.com"

      def exchange_information(symbol: nil, symbols: nil, permissions: nil, show_permission_sets: nil, symbol_status: nil)
        with_rescue do
          response = connection.get do |req|
            req.url "/api/v3/exchangeInfo"
            req.headers = headers
            req.params = {
              symbol: symbol,
              symbols: symbols&.to_json,
              permissions: permissions&.to_json,
              showPermissionSets: show_permission_sets,
              symbolStatus: symbol_status
            }.compact
          end
          response.body
        end
      end

      def symbol_price_ticker(symbol: nil, symbols: nil)
        with_rescue do
          response = connection.get do |req|
            req.url "/api/v3/ticker/price"
            req.headers = headers
            req.params = { symbol: symbol, symbols: symbols&.to_json }.compact
          end
          response.body
        end
      end

      def symbol_order_book_ticker(symbol: nil, symbols: nil)
        with_rescue do
          response = connection.get do |req|
            req.url "/api/v3/ticker/bookTicker"
            req.headers = headers
            req.params = { symbol: symbol, symbols: symbols&.to_json }.compact
          end
          response.body
        end
      end

      def candlestick_data(symbol:, interval:, start_time: nil, end_time: nil, time_zone: 0, limit: 500)
        with_rescue do
          response = connection.get do |req|
            req.url "/api/v3/klines"
            req.headers = headers
            req.params = {
              symbol: symbol, interval: interval,
              startTime: start_time, endTime: end_time,
              timeZone: time_zone, limit: limit
            }.compact
          end
          response.body
        end
      end

      def account_information(omit_zero_balances: false, recv_window: 5000)
        with_rescue do
          response = connection.get do |req|
            req.url "/api/v3/account"
            req.headers = headers
            req.params = {
              omitZeroBalances: omit_zero_balances,
              recvWindow: recv_window,
              timestamp: timestamp_ms
            }.compact
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      def account_trade_list(symbol:, order_id: nil, start_time: nil, end_time: nil, from_id: nil, limit: 500, recv_window: 5000)
        with_rescue do
          response = connection.get do |req|
            req.url "/api/v3/myTrades"
            req.headers = headers
            req.params = {
              symbol: symbol, orderId: order_id,
              startTime: start_time, endTime: end_time,
              fromId: from_id, limit: limit,
              recvWindow: recv_window, timestamp: timestamp_ms
            }.compact
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      def query_order(symbol:, order_id: nil, orig_client_order_id: nil, recv_window: 5000)
        with_rescue do
          response = connection.get do |req|
            req.url "/api/v3/order"
            req.headers = headers
            req.params = {
              symbol: symbol, orderId: order_id,
              origClientOrderId: orig_client_order_id,
              recvWindow: recv_window, timestamp: timestamp_ms
            }.compact
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      def all_orders(symbol:, order_id: nil, start_time: nil, end_time: nil, limit: 500, recv_window: 5000)
        with_rescue do
          response = connection.get do |req|
            req.url "/api/v3/allOrders"
            req.headers = headers
            req.params = {
              symbol: symbol, orderId: order_id,
              startTime: start_time, endTime: end_time,
              limit: limit, recvWindow: recv_window, timestamp: timestamp_ms
            }.compact
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      def new_order(symbol:, side:, type:, time_in_force: nil, quantity: nil, quote_order_qty: nil,
                    price: nil, new_client_order_id: nil, strategy_id: nil, strategy_type: nil,
                    stop_price: nil, trailing_delta: nil, iceberg_qty: nil, new_order_resp_type: nil,
                    self_trade_prevention_mode: nil, recv_window: 5000)
        with_rescue do
          response = connection.post do |req|
            req.url "/api/v3/order"
            req.headers = headers
            req.params = {
              symbol: symbol, side: side, type: type,
              timeInForce: time_in_force, quantity: quantity,
              quoteOrderQty: quote_order_qty, price: price,
              newClientOrderId: new_client_order_id,
              strategyId: strategy_id, strategyType: strategy_type,
              stopPrice: stop_price, trailingDelta: trailing_delta,
              icebergQty: iceberg_qty, newOrderRespType: new_order_resp_type,
              selfTradePreventionMode: self_trade_prevention_mode,
              recvWindow: recv_window, timestamp: timestamp_ms
            }.compact
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      def cancel_order(symbol:, order_id: nil, orig_client_order_id: nil, new_client_order_id: nil,
                       cancel_restrictions: nil, recv_window: 5000)
        with_rescue do
          response = connection.delete do |req|
            req.url "/api/v3/order"
            req.headers = headers
            req.params = {
              symbol: symbol, orderId: order_id,
              origClientOrderId: orig_client_order_id,
              newClientOrderId: new_client_order_id,
              cancelRestrictions: cancel_restrictions,
              recvWindow: recv_window, timestamp: timestamp_ms
            }.compact
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      def get_all_coins_information(recv_window: 5000)
        with_rescue do
          response = connection.get do |req|
            req.url "/sapi/v1/capital/config/getall"
            req.headers = headers
            req.params = { recvWindow: recv_window, timestamp: timestamp_ms }
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      def api_description(recv_window: 5000)
        with_rescue do
          response = connection.get do |req|
            req.url "/sapi/v1/account/apiRestrictions"
            req.headers = headers
            req.params = { recvWindow: recv_window, timestamp: timestamp_ms }
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      def get_withdraw_addresses(recv_window: 5000)
        with_rescue do
          response = connection.get do |req|
            req.url "/sapi/v1/capital/withdraw/address/list"
            req.headers = headers
            req.params = { recvWindow: recv_window, timestamp: timestamp_ms }
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      def withdraw(coin:, address:, amount:, network: nil, address_tag: nil, recv_window: 5000)
        with_rescue do
          response = connection.post do |req|
            req.url "/sapi/v1/capital/withdraw/apply"
            req.headers = headers
            req.params = {
              coin: coin, address: address, amount: amount,
              network: network, addressTag: address_tag,
              recvWindow: recv_window, timestamp: timestamp_ms
            }.compact
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      private

      def headers
        if authenticated?
          { "X-MBX-APIKEY": @api_key, Accept: "application/json", "Content-Type": "application/json" }
        else
          { Accept: "application/json", "Content-Type": "application/json" }
        end
      end

      def sign_params(params)
        return unless @api_secret
        query = Faraday::Utils.build_query(params)
        hmac_sha256(@api_secret, query)
      end
    end
  end
end
