# frozen_string_literal: true

module Honeymaker
  module Clients
    class BitMart < Client
      URL = "https://api-cloud.bitmart.com"

      attr_reader :memo

      def initialize(api_key: nil, api_secret: nil, memo: nil, proxy: nil, logger: nil)
        super(api_key: api_key, api_secret: api_secret, proxy: proxy, logger: logger)
        @memo = memo
      end

      def get_symbols_details
        get_public("/spot/v1/symbols/details")
      end

      def get_ticker(symbol: nil)
        get_public("/spot/quotation/v3/ticker", { symbol: symbol })
      end

      def get_depth(symbol:, limit: nil)
        get_public("/spot/quotation/v3/books", { symbol: symbol, limit: limit })
      end

      def get_klines(symbol:, step:, before: nil, after_time: nil, limit: nil)
        get_public("/spot/quotation/v3/lite-klines", {
          symbol: symbol, step: step, before: before, after: after_time, limit: limit
        })
      end

      def get_wallet
        get_signed("/spot/v1/wallet")
      end

      def submit_order(symbol:, side:, type:, size: nil, notional: nil, price: nil, client_order_id: nil)
        post_signed("/spot/v2/submit_order", {
          symbol: symbol, side: side, type: type,
          size: size, notional: notional, price: price,
          client_order_id: client_order_id
        })
      end

      def get_order(order_id:)
        post_signed("/spot/v2/order_detail", { orderId: order_id })
      end

      def cancel_order(symbol:, order_id: nil, client_order_id: nil)
        post_signed("/spot/v3/cancel_order", {
          symbol: symbol, order_id: order_id, client_order_id: client_order_id
        })
      end

      def withdraw(currency:, amount:, address:, address_memo: nil, destination: nil)
        post_signed("/account/v1/withdraw/apply", {
          currency: currency, amount: amount,
          destination: destination || "To Digital Address",
          address: address, address_memo: address_memo
        })
      end

      private

      def validate_trading_credentials
        result = get_wallet
        return Result::Failure.new("Invalid trading credentials") if result.failure?
        result.data["code"] == 1000 ? Result::Success.new(true) : Result::Failure.new("Invalid trading credentials")
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
          ts = timestamp_ms.to_s
          query_string = params.compact.empty? ? "" : "?#{Faraday::Utils.build_query(params.compact)}"
          pre_sign = "#{ts}##{@memo}##{query_string}"

          response = connection.get do |req|
            req.url path
            req.headers = signed_headers(ts, pre_sign)
            req.params = params.compact
          end
          response.body
        end
      end

      def post_signed(path, body = {})
        with_rescue do
          ts = timestamp_ms.to_s
          body_json = body.compact.to_json
          pre_sign = "#{ts}##{@memo}##{body_json}"

          response = connection.post do |req|
            req.url path
            req.headers = signed_headers(ts, pre_sign)
            req.body = body.compact
          end
          response.body
        end
      end

      def signed_headers(timestamp, pre_sign)
        signature = hmac_sha256(@api_secret, pre_sign)
        {
          "X-BM-KEY": @api_key,
          "X-BM-SIGN": signature,
          "X-BM-TIMESTAMP": timestamp,
          Accept: "application/json",
          "Content-Type": "application/json"
        }
      end
    end
  end
end
