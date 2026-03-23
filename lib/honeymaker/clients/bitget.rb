# frozen_string_literal: true

module Honeymaker
  module Clients
    class Bitget < Client
      URL = "https://api.bitget.com"

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

      def place_order(symbol:, side:, order_type:, size: nil, quote_size: nil, price: nil, force: nil, client_oid: nil)
        post_signed("/api/v2/spot/trade/place-order", {
          symbol: symbol, side: side, orderType: order_type,
          size: size, quoteSize: quote_size, price: price, force: force, clientOid: client_oid
        })
      end

      def get_order(order_id: nil, client_oid: nil)
        get_signed("/api/v2/spot/trade/orderInfo", { orderId: order_id, clientOid: client_oid })
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

      private

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
