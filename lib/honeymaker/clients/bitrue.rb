# frozen_string_literal: true

module Honeymaker
  module Clients
    class Bitrue < Client
      URL = "https://openapi.bitrue.com"
      RATE_LIMITS = { default: 100, orders: 200 }.freeze

      def exchange_information
        get_public("/api/v1/exchangeInfo")
      end

      def symbol_price_ticker(symbol: nil)
        get_public("/api/v1/ticker/price", { symbol: symbol })
      end

      # Without a symbol, /ticker/price answers nothing usable; /ticker/24hr lists every pair
      # (weight 40) with lastPrice.
      def ticker_24hr(symbol: nil)
        get_public("/api/v1/ticker/24hr", { symbol: symbol })
      end

      def symbol_order_book_ticker(symbol: nil)
        get_public("/api/v1/ticker/bookTicker", { symbol: symbol })
      end

      # Documented: symbol, scale, fromIdx, limit (max 1440). startTime/endTime are not documented and
      # are ignored; fromIdx (ms) caps the newest candle, so a walk goes back with fromIdx = oldest - 1.
      def candlestick_data(symbol:, interval:, start_time: nil, end_time: nil, limit: 500, from_idx: nil)
        get_public("/api/v1/market/kline", {
          symbol: symbol, scale: interval, startTime: start_time,
          endTime: end_time, limit: limit, fromIdx: from_idx
        })
      end

      def account_information(recv_window: 5000)
        get_signed("/api/v1/account", { recvWindow: recv_window })
      end

      def get_balances
        result = account_information
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

      def query_order(symbol:, order_id: nil, orig_client_order_id: nil, recv_window: 5000)
        result = get_signed("/api/v1/order", {
          symbol: symbol, orderId: order_id,
          origClientOrderId: orig_client_order_id, recvWindow: recv_window
        })
        return result if result.failure?

        raw = result.data
        Result::Success.new(normalize_order("#{symbol}-#{raw['orderId']}", raw))
      end

      def new_order(symbol:, side:, type:, time_in_force: nil, quantity: nil, quote_order_qty: nil,
                    price: nil, new_client_order_id: nil, recv_window: 5000)
        result = post_signed("/api/v1/order", {
          symbol: symbol, side: side, type: type,
          timeInForce: time_in_force, quantity: quantity,
          quoteOrderQty: quote_order_qty, price: price,
          newClientOrderId: new_client_order_id, recvWindow: recv_window
        })
        return result if result.failure?

        raw = result.data
        Result::Success.new({ order_id: "#{symbol}-#{raw['orderId']}", raw: raw })
      end

      def cancel_order(symbol:, order_id: nil, orig_client_order_id: nil, recv_window: 5000)
        delete_signed("/api/v1/order", {
          symbol: symbol, orderId: order_id,
          origClientOrderId: orig_client_order_id, recvWindow: recv_window
        })
      end

      # /api/v1/capital/config/getall redirects to the website. The documented source of withdrawal
      # networks and fees is the public exchangeInfo `coins[].chainDetail[]`; it is answered here in the
      # Binance shape the method always promised: [{ "coin", "networkList" => [{ "network",
      # "withdrawFee", "withdrawMin", "withdrawMax", "withdrawEnable", "depositEnable", "isDefault" }] }].
      # Bitrue marks no default chain; a chain closed for withdrawal is left out.
      def get_all_coins_information
        result = exchange_information
        return result if result.failure?

        coins = Array(result.data["coins"]).map do |coin|
          networks = Array(coin["chainDetail"]).select { |c| c["enableWithdraw"] }.map do |c|
            { "network" => c["chain"], "withdrawFee" => c["withdrawFee"], "withdrawMin" => c["minWithdraw"],
              "withdrawMax" => c["maxWithdraw"], "withdrawEnable" => true,
              "depositEnable" => c["enableDeposit"], "isDefault" => false }
          end
          { "coin" => coin["coin"].to_s.upcase, "networkList" => networks }
        end
        Result::Success.new(coins)
      end

      # POST /api/v1/withdraw/commit: coin without chain name, chainName, addressTo; needs the
      # withdraw privilege, an IP-limited key and a whitelisted address.
      def withdraw(coin:, address:, amount:, network:, address_tag: nil, recv_window: 5000)
        post_signed("/api/v1/withdraw/commit", {
          coin: coin, amount: amount, addressTo: address,
          chainName: network, tag: address_tag, recvWindow: recv_window
        })
      end

      # GET /api/v2/myTrades (v1 is undocumented): limit ≤ 1000, a startTime..endTime span ≤ 3 months.
      def account_trade_list(symbol:, start_time: nil, end_time: nil, from_id: nil, limit: 500, recv_window: 5000)
        get_signed("/api/v2/myTrades", {
          symbol: symbol, startTime: start_time, endTime: end_time,
          fromId: from_id, limit: limit, recvWindow: recv_window
        })
      end

      # GET /api/v1/deposit/history and /api/v1/withdraw/history (the /capital/ paths redirect to the
      # website): coin is required and has no chain suffix; status defaults to 0 (init) — finished is
      # 1 for a deposit, 5 for a withdrawal; offset + limit ≤ 1000; answers { "code" => 200, "data" => [...] }.
      def deposit_history(coin:, status: nil, start_time: nil, end_time: nil, offset: nil, limit: 1000, recv_window: 5000)
        get_signed("/api/v1/deposit/history", {
          coin: coin, status: status,
          startTime: start_time, endTime: end_time,
          offset: offset, limit: limit, recvWindow: recv_window
        })
      end

      def withdraw_history(coin:, status: nil, start_time: nil, end_time: nil, offset: nil, limit: 1000, recv_window: 5000)
        get_signed("/api/v1/withdraw/history", {
          coin: coin, status: status,
          startTime: start_time, endTime: end_time,
          offset: offset, limit: limit, recvWindow: recv_window
        })
      end

      # --- Futures ---

      def futures_account(recv_window: 5000)
        with_rescue do
          response = futures_connection.get do |req|
            req.url "/fapi/v1/account"
            req.headers = auth_headers
            req.params = { recvWindow: recv_window, timestamp: timestamp_ms }.compact
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      private

      def futures_connection
        @futures_connection ||= build_client_connection("https://fapi.bitrue.com")
      end

      def normalize_order(order_id, raw)
        order_type = parse_order_type(raw["type"])
        side = raw["side"]&.downcase&.to_sym
        status = parse_order_status(raw["status"])

        amount = BigDecimal((raw["origQty"] || "0").to_s)
        amount = nil if amount.zero?
        quote_amount = raw["origQuoteOrderQty"] ? BigDecimal(raw["origQuoteOrderQty"].to_s) : nil
        quote_amount = nil if quote_amount&.zero?

        amount_exec = BigDecimal((raw["executedQty"] || "0").to_s)
        quote_amount_exec = BigDecimal((raw["cummulativeQuoteQty"] || "0").to_s)
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
        when "MARKET" then :market
        when "LIMIT" then :limit
        else :unknown
        end
      end

      def parse_order_status(status)
        case status
        when "NEW", "PARTIALLY_FILLED" then :open
        when "FILLED" then :closed
        when "CANCELED", "EXPIRED" then :cancelled
        when "REJECTED" then :failed
        else :unknown
        end
      end

      def validate_trading_credentials
        result = account_information
        result.success? ? Result::Success.new(true) : Result::Failure.new("Invalid trading credentials")
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
