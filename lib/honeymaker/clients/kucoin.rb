# frozen_string_literal: true

module Honeymaker
  module Clients
    class Kucoin < Client
      URL = "https://api.kucoin.com"
      RATE_LIMITS = { default: 100, orders: 200 }.freeze

      attr_reader :passphrase

      def initialize(api_key: nil, api_secret: nil, passphrase: nil, proxy: nil, logger: nil)
        super(api_key: api_key, api_secret: api_secret, proxy: proxy, logger: logger)
        @passphrase = passphrase
      end

      def get_symbols
        get_public("/api/v2/symbols")
      end

      def get_ticker(symbol:)
        get_public("/api/v1/market/orderbook/level1", { symbol: symbol })
      end

      def get_all_tickers
        get_public("/api/v1/market/allTickers")
      end

      def get_klines(symbol:, type:, start_at: nil, end_at: nil)
        get_public("/api/v1/market/candles", {
          symbol: symbol, type: type, startAt: start_at, endAt: end_at
        })
      end

      def get_accounts(currency: nil, type: nil)
        get_signed("/api/v1/accounts", { currency: currency, type: type })
      end

      def get_balances(type: "trade")
        result = get_accounts(type: type)
        return result if result.failure?

        return Result::Failure.new("KuCoin API error") unless result.data["code"] == "200000"

        balances = {}
        (result.data["data"] || []).each do |account|
          symbol = account["currency"]
          free = BigDecimal((account["available"] || "0").to_s)
          locked = BigDecimal((account["holds"] || "0").to_s)
          next if free.zero? && locked.zero?
          balances[symbol] = { free: free, locked: locked }
        end

        Result::Success.new(balances)
      end

      def place_order(client_oid:, side:, symbol:, type:, size: nil, funds: nil, price: nil,
                      time_in_force: nil, stp: nil)
        result = post_signed("/api/v1/orders", {
          clientOid: client_oid, side: side, symbol: symbol, type: type,
          size: size, funds: funds, price: price,
          timeInForce: time_in_force, stp: stp
        })
        return result if result.failure?
        return Result::Failure.new("KuCoin API error") unless result.data["code"] == "200000"

        order_id = result.data.dig("data", "orderId")
        Result::Success.new({ order_id: order_id, raw: result.data })
      end

      def get_order(order_id:)
        result = get_signed("/api/v1/orders/#{order_id}")
        return result if result.failure?
        return Result::Failure.new("KuCoin API error") unless result.data["code"] == "200000"

        raw = result.data["data"]
        return Result::Failure.new("Order not found") unless raw

        Result::Success.new(normalize_order(order_id, raw))
      end

      def cancel_order(order_id:)
        delete_signed("/api/v1/orders/#{order_id}")
      end

      def get_currencies
        get_public("/api/v3/currencies")
      end

      def get_withdrawal_quotas(currency:, chain: nil)
        get_signed("/api/v1/withdrawals/quotas", { currency: currency, chain: chain })
      end

      def get_fills(order_id: nil, symbol: nil, side: nil, type: nil, start_at: nil, end_at: nil,
                    trade_type: nil, limit: nil, current_page: nil)
        get_signed("/api/v1/fills", {
          orderId: order_id, symbol: symbol, side: side, type: type,
          startAt: start_at, endAt: end_at, tradeType: trade_type,
          pageSize: limit, currentPage: current_page
        })
      end

      def get_historical_orders(symbol: nil, side: nil, start_at: nil, end_at: nil, current_page: nil, page_size: nil)
        get_signed("/api/v1/hist-orders", {
          symbol: symbol, side: side,
          startAt: start_at, endAt: end_at,
          currentPage: current_page, pageSize: page_size
        })
      end

      def get_deposits(currency: nil, start_at: nil, end_at: nil, status: nil, current_page: nil, page_size: nil)
        get_signed("/api/v1/deposits", {
          currency: currency, startAt: start_at, endAt: end_at,
          status: status, currentPage: current_page, pageSize: page_size
        })
      end

      def get_withdrawals(currency: nil, start_at: nil, end_at: nil, status: nil, current_page: nil, page_size: nil)
        get_signed("/api/v1/withdrawals", {
          currency: currency, startAt: start_at, endAt: end_at,
          status: status, currentPage: current_page, pageSize: page_size
        })
      end

      def withdraw(currency:, address:, amount:, chain: nil, memo: nil)
        post_signed("/api/v1/withdrawals", {
          currency: currency, address: address, amount: amount,
          chain: chain, memo: memo
        })
      end

      private

      def normalize_order(order_id, raw)
        order_type = parse_order_type(raw["type"])
        side = raw["side"]&.downcase&.to_sym
        status = parse_order_status(raw)

        deal_funds = BigDecimal((raw["dealFunds"] || "0").to_s)
        deal_size = BigDecimal((raw["dealSize"] || "0").to_s)
        price = deal_funds.positive? && deal_size.positive? ? deal_funds / deal_size : BigDecimal((raw["price"] || "0").to_s)
        price = nil if price.zero?

        amount = raw["size"] ? BigDecimal(raw["size"].to_s) : nil
        quote_amount = raw["funds"] ? BigDecimal(raw["funds"].to_s) : nil

        {
          order_id: order_id, status: status, side: side, order_type: order_type,
          price: price, amount: amount, quote_amount: quote_amount,
          amount_exec: deal_size, quote_amount_exec: deal_funds, raw: raw
        }
      end

      def parse_order_type(type)
        case type&.downcase
        when "market" then :market
        when "limit" then :limit
        else :unknown
        end
      end

      def parse_order_status(raw)
        if raw["cancelExist"]
          :cancelled
        elsif raw["isActive"]
          :open
        else
          BigDecimal((raw["dealSize"] || "0").to_s).positive? ? :closed : :unknown
        end
      end

      def validate_trading_credentials
        result = get_accounts(type: "trade")
        return Result::Failure.new("Invalid trading credentials") if result.failure?
        result.data["code"] == "200000" ? Result::Success.new(true) : Result::Failure.new("Invalid trading credentials")
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

      def delete_signed(path)
        with_rescue do
          ts = timestamp_ms.to_s
          pre_sign = "#{ts}DELETE#{path}"

          response = connection.delete do |req|
            req.url path
            req.headers = signed_headers(ts, pre_sign)
          end
          response.body
        end
      end

      def unauthenticated_headers
        { Accept: "application/json", "Content-Type": "application/json" }
      end

      def signed_headers(timestamp, pre_sign)
        signature = Base64.strict_encode64(OpenSSL::HMAC.digest("sha256", @api_secret, pre_sign))
        signed_passphrase = Base64.strict_encode64(
          OpenSSL::HMAC.digest("sha256", @api_secret, @passphrase)
        )
        {
          "KC-API-KEY": @api_key,
          "KC-API-SIGN": signature,
          "KC-API-TIMESTAMP": timestamp,
          "KC-API-PASSPHRASE": signed_passphrase,
          "KC-API-KEY-VERSION": "2",
          Accept: "application/json",
          "Content-Type": "application/json"
        }
      end
    end
  end
end
