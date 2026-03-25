# frozen_string_literal: true

module Honeymaker
  module Clients
    class Binance < Client
      URL = "https://api.binance.com"
      RATE_LIMITS = { default: 100, orders: 200 }.freeze

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

      def get_balances
        result = account_information(omit_zero_balances: true)
        return result if result.failure?

        balances = {}
        Array(result.data["balances"]).each do |balance|
          symbol = balance["asset"]
          free = BigDecimal(balance["free"].to_s)
          locked = BigDecimal(balance["locked"].to_s)
          next if free.zero? && locked.zero?
          balances[symbol] = { free: free, locked: locked }
        end

        Result::Success.new(balances)
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
          raw = response.body
          normalize_order("#{symbol}-#{raw['orderId']}", raw)
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
          raw = response.body
          { order_id: "#{symbol}-#{raw['orderId']}", raw: raw }
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

      def deposit_history(coin: nil, status: nil, start_time: nil, end_time: nil, offset: nil, limit: 1000, recv_window: 5000)
        with_rescue do
          response = connection.get do |req|
            req.url "/sapi/v1/capital/deposit/hisrec"
            req.headers = headers
            req.params = {
              coin: coin, status: status,
              startTime: start_time, endTime: end_time,
              offset: offset, limit: limit,
              recvWindow: recv_window, timestamp: timestamp_ms
            }.compact
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      def withdraw_history(coin: nil, status: nil, start_time: nil, end_time: nil, offset: nil, limit: 1000, recv_window: 5000)
        with_rescue do
          response = connection.get do |req|
            req.url "/sapi/v1/capital/withdraw/history"
            req.headers = headers
            req.params = {
              coin: coin, status: status,
              startTime: start_time, endTime: end_time,
              offset: offset, limit: limit,
              recvWindow: recv_window, timestamp: timestamp_ms
            }.compact
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      def convert_trade_flow(start_time:, end_time:, limit: 1000, recv_window: 5000)
        with_rescue do
          response = connection.get do |req|
            req.url "/sapi/v1/convert/tradeFlow"
            req.headers = headers
            req.params = {
              startTime: start_time, endTime: end_time,
              limit: limit, recvWindow: recv_window, timestamp: timestamp_ms
            }.compact
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      def fiat_payments(transaction_type:, begin_time: nil, end_time: nil, page: nil, rows: nil, recv_window: 5000)
        with_rescue do
          response = connection.get do |req|
            req.url "/sapi/v1/fiat/payments"
            req.headers = headers
            req.params = {
              transactionType: transaction_type,
              beginTime: begin_time, endTime: end_time,
              page: page, rows: rows,
              recvWindow: recv_window, timestamp: timestamp_ms
            }.compact
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      def fiat_orders(transaction_type:, begin_time: nil, end_time: nil, page: nil, rows: nil, recv_window: 5000)
        with_rescue do
          response = connection.get do |req|
            req.url "/sapi/v1/fiat/orders"
            req.headers = headers
            req.params = {
              transactionType: transaction_type,
              beginTime: begin_time, endTime: end_time,
              page: page, rows: rows,
              recvWindow: recv_window, timestamp: timestamp_ms
            }.compact
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      def dust_log(start_time: nil, end_time: nil, recv_window: 5000)
        with_rescue do
          response = connection.get do |req|
            req.url "/sapi/v1/asset/dribblet"
            req.headers = headers
            req.params = {
              startTime: start_time, endTime: end_time,
              recvWindow: recv_window, timestamp: timestamp_ms
            }.compact
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      def asset_dividend(asset: nil, start_time: nil, end_time: nil, limit: 500, recv_window: 5000)
        with_rescue do
          response = connection.get do |req|
            req.url "/sapi/v1/asset/assetDividend"
            req.headers = headers
            req.params = {
              asset: asset, startTime: start_time, endTime: end_time,
              limit: limit, recvWindow: recv_window, timestamp: timestamp_ms
            }.compact
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      def simple_earn_flexible_rewards(asset: nil, start_time: nil, end_time: nil, current: nil, size: nil)
        with_rescue do
          response = connection.get do |req|
            req.url "/sapi/v1/simple-earn/flexible/history/rewardsRecord"
            req.headers = headers
            req.params = {
              asset: asset, startTime: start_time, endTime: end_time,
              current: current, size: size, timestamp: timestamp_ms
            }.compact
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      def simple_earn_locked_rewards(asset: nil, start_time: nil, end_time: nil, current: nil, size: nil)
        with_rescue do
          response = connection.get do |req|
            req.url "/sapi/v1/simple-earn/locked/history/rewardsRecord"
            req.headers = headers
            req.params = {
              asset: asset, startTime: start_time, endTime: end_time,
              current: current, size: size, timestamp: timestamp_ms
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

      # --- Margin ---

      def margin_borrow_repay_history(type:, asset: nil, isolated_symbol: nil, start_time: nil, end_time: nil,
                                      current: nil, size: nil, recv_window: 5000)
        with_rescue do
          response = connection.get do |req|
            req.url "/sapi/v1/margin/borrow-repay"
            req.headers = headers
            req.params = {
              type: type, asset: asset, isolatedSymbol: isolated_symbol,
              startTime: start_time, endTime: end_time,
              current: current, size: size,
              recvWindow: recv_window, timestamp: timestamp_ms
            }.compact
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      def margin_interest_history(asset: nil, isolated_symbol: nil, start_time: nil, end_time: nil,
                                  current: nil, size: nil, archived: nil, recv_window: 5000)
        with_rescue do
          response = connection.get do |req|
            req.url "/sapi/v1/margin/interestHistory"
            req.headers = headers
            req.params = {
              asset: asset, isolatedSymbol: isolated_symbol,
              startTime: start_time, endTime: end_time,
              current: current, size: size, archived: archived,
              recvWindow: recv_window, timestamp: timestamp_ms
            }.compact
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      def margin_force_liquidation(start_time: nil, end_time: nil, isolated_symbol: nil,
                                   current: nil, size: nil, recv_window: 5000)
        with_rescue do
          response = connection.get do |req|
            req.url "/sapi/v1/margin/forceLiquidationRec"
            req.headers = headers
            req.params = {
              startTime: start_time, endTime: end_time,
              isolatedSymbol: isolated_symbol,
              current: current, size: size,
              recvWindow: recv_window, timestamp: timestamp_ms
            }.compact
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      # --- Futures ---

      def futures_income_history(symbol: nil, income_type: nil, start_time: nil, end_time: nil,
                                 page: nil, limit: 1000, recv_window: 5000)
        with_rescue do
          response = usdt_futures_connection.get do |req|
            req.url "/fapi/v1/income"
            req.headers = headers
            req.params = {
              symbol: symbol, incomeType: income_type,
              startTime: start_time, endTime: end_time,
              page: page, limit: limit,
              recvWindow: recv_window, timestamp: timestamp_ms
            }.compact
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      def coin_futures_income_history(symbol: nil, income_type: nil, start_time: nil, end_time: nil,
                                      page: nil, limit: 1000, recv_window: 5000)
        with_rescue do
          response = coin_futures_connection.get do |req|
            req.url "/dapi/v1/income"
            req.headers = headers
            req.params = {
              symbol: symbol, incomeType: income_type,
              startTime: start_time, endTime: end_time,
              page: page, limit: limit,
              recvWindow: recv_window, timestamp: timestamp_ms
            }.compact
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      # --- Simple Earn ---

      def simple_earn_flexible_subscriptions(product_id: nil, purchase_id: nil, asset: nil,
                                             start_time: nil, end_time: nil, current: nil, size: nil)
        with_rescue do
          response = connection.get do |req|
            req.url "/sapi/v1/simple-earn/flexible/history/subscriptionRecord"
            req.headers = headers
            req.params = {
              productId: product_id, purchaseId: purchase_id, asset: asset,
              startTime: start_time, endTime: end_time,
              current: current, size: size, timestamp: timestamp_ms
            }.compact
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      def simple_earn_flexible_redemptions(product_id: nil, redeem_id: nil, asset: nil,
                                           start_time: nil, end_time: nil, current: nil, size: nil)
        with_rescue do
          response = connection.get do |req|
            req.url "/sapi/v1/simple-earn/flexible/history/redemptionRecord"
            req.headers = headers
            req.params = {
              productId: product_id, redeemId: redeem_id, asset: asset,
              startTime: start_time, endTime: end_time,
              current: current, size: size, timestamp: timestamp_ms
            }.compact
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      def simple_earn_locked_subscriptions(product_id: nil, purchase_id: nil, asset: nil,
                                           start_time: nil, end_time: nil, current: nil, size: nil)
        with_rescue do
          response = connection.get do |req|
            req.url "/sapi/v1/simple-earn/locked/history/subscriptionRecord"
            req.headers = headers
            req.params = {
              productId: product_id, purchaseId: purchase_id, asset: asset,
              startTime: start_time, endTime: end_time,
              current: current, size: size, timestamp: timestamp_ms
            }.compact
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      def simple_earn_locked_redemptions(product_id: nil, redeem_id: nil, asset: nil,
                                         start_time: nil, end_time: nil, current: nil, size: nil)
        with_rescue do
          response = connection.get do |req|
            req.url "/sapi/v1/simple-earn/locked/history/redemptionRecord"
            req.headers = headers
            req.params = {
              productId: product_id, redeemId: redeem_id, asset: asset,
              startTime: start_time, endTime: end_time,
              current: current, size: size, timestamp: timestamp_ms
            }.compact
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      # --- Transfers ---

      def universal_transfer_history(type:, start_time: nil, end_time: nil, current: nil, size: nil, recv_window: 5000)
        with_rescue do
          response = connection.get do |req|
            req.url "/sapi/v1/asset/transfer"
            req.headers = headers
            req.params = {
              type: type, startTime: start_time, endTime: end_time,
              current: current, size: size,
              recvWindow: recv_window, timestamp: timestamp_ms
            }.compact
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      private

      def usdt_futures_connection
        @usdt_futures_connection ||= build_client_connection("https://fapi.binance.com")
      end

      def coin_futures_connection
        @coin_futures_connection ||= build_client_connection("https://dapi.binance.com")
      end

      def normalize_order(order_id, raw)
        order_type = parse_order_type(raw["type"])
        side = raw["side"]&.downcase&.to_sym
        status = parse_order_status(raw["status"])

        amount = BigDecimal(raw["origQty"].to_s)
        amount = nil if amount.zero?
        quote_amount = BigDecimal(raw["origQuoteOrderQty"].to_s)
        quote_amount = nil if quote_amount.zero?

        amount_exec = BigDecimal(raw["executedQty"].to_s)
        quote_amount_exec = BigDecimal(raw["cummulativeQuoteQty"].to_s)
        quote_amount_exec = nil if quote_amount_exec.negative?

        price = BigDecimal(raw["price"].to_s)
        if price.zero? && quote_amount_exec&.positive? && amount_exec.positive?
          price = quote_amount_exec / amount_exec
        end
        price = nil if price.zero?

        {
          order_id: order_id,
          status: status,
          side: side,
          order_type: order_type,
          price: price,
          amount: amount,
          quote_amount: quote_amount,
          amount_exec: amount_exec,
          quote_amount_exec: quote_amount_exec,
          raw: raw
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
        when "PENDING_CANCEL" then :unknown
        when "NEW", "PENDING_NEW", "PARTIALLY_FILLED" then :open
        when "FILLED" then :closed
        when "CANCELED", "EXPIRED", "EXPIRED_IN_MATCH" then :cancelled
        when "REJECTED" then :failed
        else :unknown
        end
      end

      def validate_trading_credentials
        # Try cancelling a non-existent order — error -2011 (ORDER_DOES_NOT_EXIST) means key is valid with trade permission
        result = cancel_order(symbol: "ETHBTC", order_id: "9999999999")
        return Result::Failure.new("Invalid trading credentials") if result.failure?

        code = result.data.is_a?(Hash) ? result.data["code"] : nil
        code == -2011 ? Result::Success.new(true) : Result::Failure.new("Invalid trading credentials")
      end

      def validate_read_credentials
        result = api_description
        Result.new(data: result.success?, errors: result.success? ? [] : ["Invalid read credentials"])
      end

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
