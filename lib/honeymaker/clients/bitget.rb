# frozen_string_literal: true

module Honeymaker
  module Clients
    class Bitget < Client
      URL = "https://api.bitget.com"
      RATE_LIMITS = { default: 100, orders: 200 }.freeze

      attr_reader :passphrase

      def initialize(api_key: nil, api_secret: nil, passphrase: nil, proxy: nil, logger: nil)
        super(api_key: api_key, api_secret: api_secret, proxy: proxy, logger: logger)
        @passphrase = passphrase
      end

      def get_coins
        get_public("/api/v2/spot/public/coins")
      end

      def get_symbols
        get_public("/api/v2/spot/public/symbols")
      end

      def get_tickers(symbol: nil)
        get_public("/api/v2/spot/market/tickers", { symbol: symbol })
      end

      def get_orderbook(symbol:, limit: nil)
        get_public("/api/v2/spot/market/orderbook", { symbol: symbol, limit: limit })
      end

      def get_candles(symbol:, granularity:, start_time: nil, end_time: nil, limit: nil)
        get_public("/api/v2/spot/market/candles", {
          symbol: symbol, granularity: granularity,
          startTime: start_time, endTime: end_time, limit: limit
        })
      end

      def get_account_assets(coin: nil)
        get_signed("/api/v2/spot/account/assets", { coin: coin })
      end

      def get_balances
        result = get_account_assets
        return result if result.failure?

        return Result::Failure.new("Bitget API error") unless result.data["code"] == "00000"

        balances = {}
        (result.data["data"] || []).each do |asset|
          symbol = asset["coin"]
          free = BigDecimal((asset["available"] || "0").to_s)
          locked = BigDecimal((asset["frozen"] || "0").to_s)
          next if free.zero? && locked.zero?
          balances[symbol] = { free: free, locked: locked }
        end

        Result::Success.new(balances)
      end

      def place_order(symbol:, side:, order_type:, size: nil, quote_size: nil, price: nil, force: nil, client_oid: nil)
        result = post_signed("/api/v2/spot/trade/place-order", {
          symbol: symbol, side: side, orderType: order_type,
          size: size, quoteSize: quote_size, price: price, force: force, clientOid: client_oid
        })
        return result if result.failure?
        return Result::Failure.new("Bitget API error") unless result.data["code"] == "00000"

        order_id = result.data.dig("data", "orderId")
        Result::Success.new({ order_id: "#{symbol}-#{order_id}", raw: result.data })
      end

      def get_order(order_id: nil, client_oid: nil)
        result = get_signed("/api/v2/spot/trade/orderInfo", { orderId: order_id, clientOid: client_oid })
        return result if result.failure?
        return Result::Failure.new("Bitget API error") unless result.data["code"] == "00000"

        order_list = result.data["data"]
        raw = order_list.is_a?(Array) ? order_list.first : order_list
        return Result::Failure.new("Order not found") unless raw

        Result::Success.new(normalize_order(raw["orderId"] || order_id, raw))
      end

      def cancel_order(symbol:, order_id: nil, client_oid: nil)
        post_signed("/api/v2/spot/trade/cancel-order", {
          symbol: symbol, orderId: order_id, clientOid: client_oid
        })
      end

      def get_fills(symbol: nil, order_id: nil, start_time: nil, end_time: nil, limit: nil, id_less_than: nil)
        get_signed("/api/v2/spot/trade/fills", {
          symbol: symbol, orderId: order_id,
          startTime: start_time, endTime: end_time, limit: limit, idLessThan: id_less_than
        })
      end

      def deposit_list(coin: nil, start_time: nil, end_time: nil, limit: nil, id_less_than: nil)
        get_signed("/api/v2/spot/wallet/deposit-records", {
          coin: coin, startTime: start_time, endTime: end_time, limit: limit, idLessThan: id_less_than
        })
      end

      def withdrawal_list(coin: nil, start_time: nil, end_time: nil, limit: nil, id_less_than: nil)
        get_signed("/api/v2/spot/wallet/withdrawal-records", {
          coin: coin, startTime: start_time, endTime: end_time, limit: limit, idLessThan: id_less_than
        })
      end

      def withdraw(coin:, address:, size:, transfer_type: nil, chain: nil, tag: nil, client_oid: nil)
        post_signed("/api/v2/spot/wallet/withdrawal", {
          coin: coin, transferType: transfer_type, address: address,
          size: size, chain: chain, tag: tag, clientOid: client_oid
        })
      end

      # --- Margin (Cross) ---

      def margin_crossed_borrow_history(loan_id: nil, coin: nil, start_time: nil, end_time: nil, limit: nil, id_less_than: nil)
        get_signed("/api/v2/margin/crossed/borrow-history", {
          loanId: loan_id, coin: coin,
          startTime: start_time, endTime: end_time, limit: limit, idLessThan: id_less_than
        })
      end

      def margin_crossed_repay_history(repay_id: nil, coin: nil, start_time: nil, end_time: nil, limit: nil, id_less_than: nil)
        get_signed("/api/v2/margin/crossed/repay-history", {
          repayId: repay_id, coin: coin,
          startTime: start_time, endTime: end_time, limit: limit, idLessThan: id_less_than
        })
      end

      def margin_crossed_interest_history(coin: nil, start_time: nil, end_time: nil, limit: nil, id_less_than: nil)
        get_signed("/api/v2/margin/crossed/interest-history", {
          coin: coin, startTime: start_time, endTime: end_time, limit: limit, idLessThan: id_less_than
        })
      end

      def margin_crossed_liquidation_history(start_time: nil, end_time: nil, limit: nil, id_less_than: nil)
        get_signed("/api/v2/margin/crossed/liquidation-history", {
          startTime: start_time, endTime: end_time, limit: limit, idLessThan: id_less_than
        })
      end

      # --- Margin (Isolated) ---

      def margin_isolated_borrow_history(symbol: nil, loan_id: nil, coin: nil, start_time: nil, end_time: nil, limit: nil, id_less_than: nil)
        get_signed("/api/v2/margin/isolated/borrow-history", {
          symbol: symbol, loanId: loan_id, coin: coin,
          startTime: start_time, endTime: end_time, limit: limit, idLessThan: id_less_than
        })
      end

      def margin_isolated_repay_history(symbol: nil, repay_id: nil, coin: nil, start_time: nil, end_time: nil, limit: nil, id_less_than: nil)
        get_signed("/api/v2/margin/isolated/repay-history", {
          symbol: symbol, repayId: repay_id, coin: coin,
          startTime: start_time, endTime: end_time, limit: limit, idLessThan: id_less_than
        })
      end

      def margin_isolated_interest_history(symbol: nil, coin: nil, start_time: nil, end_time: nil, limit: nil, id_less_than: nil)
        get_signed("/api/v2/margin/isolated/interest-history", {
          symbol: symbol, coin: coin,
          startTime: start_time, endTime: end_time, limit: limit, idLessThan: id_less_than
        })
      end

      def margin_isolated_liquidation_history(symbol: nil, start_time: nil, end_time: nil, limit: nil, id_less_than: nil)
        get_signed("/api/v2/margin/isolated/liquidation-history", {
          symbol: symbol, startTime: start_time, endTime: end_time, limit: limit, idLessThan: id_less_than
        })
      end

      # --- Futures ---

      def futures_account_bills(product_type:, coin: nil, business: nil, start_time: nil, end_time: nil, limit: nil, id_less_than: nil)
        get_signed("/api/v2/mix/account/bill", {
          productType: product_type, coin: coin, business: business,
          startTime: start_time, endTime: end_time, limit: limit, idLessThan: id_less_than
        })
      end

      def futures_fills_history(product_type:, symbol: nil, order_id: nil, start_time: nil, end_time: nil, limit: nil, id_less_than: nil)
        get_signed("/api/v2/mix/order/fills-history", {
          productType: product_type, symbol: symbol, orderId: order_id,
          startTime: start_time, endTime: end_time, limit: limit, idLessThan: id_less_than
        })
      end

      # --- Earn ---

      def earn_savings_assets(coin: nil, filter: nil)
        get_signed("/api/v2/earn/savings/assets", { coin: coin, filter: filter })
      end

      def earn_savings_subscribe_result(coin: nil, start_time: nil, end_time: nil, limit: nil, id_less_than: nil)
        get_signed("/api/v2/earn/savings/subscribe-result", {
          coin: coin, startTime: start_time, endTime: end_time, limit: limit, idLessThan: id_less_than
        })
      end

      def earn_savings_redeem_result(coin: nil, start_time: nil, end_time: nil, limit: nil, id_less_than: nil)
        get_signed("/api/v2/earn/savings/redeem-result", {
          coin: coin, startTime: start_time, endTime: end_time, limit: limit, idLessThan: id_less_than
        })
      end

      private

      def normalize_order(order_id, raw)
        order_type = parse_order_type(raw["orderType"])
        side = raw["side"]&.downcase&.to_sym
        status = parse_order_status(raw["status"])

        price = BigDecimal((raw["priceAvg"] || raw["price"] || "0").to_s)
        price = nil if price.zero?

        amount = raw["size"] ? BigDecimal(raw["size"].to_s) : nil
        quote_amount = raw["quoteSize"] ? BigDecimal(raw["quoteSize"].to_s) : nil
        amount_exec = BigDecimal((raw["baseVolume"] || "0").to_s)
        quote_amount_exec = BigDecimal((raw["quoteVolume"] || "0").to_s)

        {
          order_id: order_id, status: status, side: side, order_type: order_type,
          price: price, amount: amount, quote_amount: quote_amount,
          amount_exec: amount_exec, quote_amount_exec: quote_amount_exec, raw: raw
        }
      end

      def parse_order_type(type)
        case type&.downcase
        when "market" then :market
        when "limit" then :limit
        else :unknown
        end
      end

      def parse_order_status(status)
        case status
        when "init", "new" then :unknown
        when "partial_fill", "live" then :open
        when "full_fill" then :closed
        when "cancelled" then :cancelled
        else :unknown
        end
      end

      def validate_trading_credentials
        result = get_account_assets
        return Result::Failure.new("Invalid trading credentials") if result.failure?
        result.data["code"] == "00000" ? Result::Success.new(true) : Result::Failure.new("Invalid trading credentials")
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
          query_string = params.empty? ? "" : "?#{Faraday::Utils.build_query(params)}"
          ts = timestamp_ms.to_s
          pre_sign = "#{ts}GET#{path}#{query_string}"

          response = connection.get do |req|
            req.url path
            req.headers = signed_headers(ts, pre_sign)
            req.params = params
          end
          response.body
        end
      end

      def post_signed(path, body = {})
        with_rescue do
          body = body.compact
          ts = timestamp_ms.to_s
          pre_sign = "#{ts}POST#{path}#{body.to_json}"

          response = connection.post do |req|
            req.url path
            req.headers = signed_headers(ts, pre_sign)
            req.body = body
          end
          response.body
        end
      end

      def unauthenticated_headers
        { Accept: "application/json", "Content-Type": "application/json" }
      end

      def signed_headers(timestamp, pre_sign)
        mac = Base64.strict_encode64(OpenSSL::HMAC.digest("sha256", @api_secret, pre_sign))
        {
          "ACCESS-KEY": @api_key,
          "ACCESS-SIGN": mac,
          "ACCESS-TIMESTAMP": timestamp,
          "ACCESS-PASSPHRASE": @passphrase,
          Accept: "application/json",
          "Content-Type": "application/json",
          locale: "en-US"
        }
      end
    end
  end
end
