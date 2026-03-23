# frozen_string_literal: true

module Honeymaker
  module Clients
    class Gemini < Client
      URL = "https://api.gemini.com"

      def get_symbols
        get_public("/v1/symbols")
      end

      def get_symbol_details(symbol:)
        get_public("/v1/symbols/details/#{symbol}")
      end

      def get_ticker(symbol:)
        get_public("/v1/pubticker/#{symbol}")
      end

      def get_candles(symbol:, time_frame:)
        get_public("/v2/candles/#{symbol}/#{time_frame}")
      end

      def get_balances
        post_signed("/v1/balances")
      end

      def new_order(symbol:, amount:, price:, side:, type:, client_order_id: nil, options: [])
        post_signed("/v1/order/new", {
          symbol: symbol, amount: amount, price: price,
          side: side, type: type, client_order_id: client_order_id,
          options: options
        })
      end

      def order_status(order_id:)
        post_signed("/v1/order/status", { order_id: order_id })
      end

      def cancel_order(order_id:)
        post_signed("/v1/order/cancel", { order_id: order_id })
      end

      def get_my_trades(symbol: nil, limit_trades: nil, timestamp: nil)
        post_signed("/v1/mytrades", { symbol: symbol, limit_trades: limit_trades, timestamp: timestamp })
      end

      def get_transfers(timestamp: nil, limit_transfers: nil)
        post_signed("/v1/transfers", { timestamp: timestamp, limit_transfers: limit_transfers })
      end

      def withdraw(currency:, address:, amount:)
        post_signed("/v1/withdraw/#{currency}", { address: address, amount: amount })
      end

      private

      def validate_trading_credentials
        result = get_balances
        return Result::Failure.new("Invalid trading credentials") if result.failure?
        result.data.is_a?(Array) ? Result::Success.new(true) : Result::Failure.new("Invalid trading credentials")
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

      def post_signed(path, body = {})
        with_rescue do
          payload = body.compact.merge(request: path, nonce: timestamp_ms.to_s)
          encoded_payload = Base64.strict_encode64(payload.to_json)
          signature = hmac_sha256(@api_secret, encoded_payload)

          response = connection.post do |req|
            req.url path
            req.headers = {
              "X-GEMINI-APIKEY": @api_key,
              "X-GEMINI-PAYLOAD": encoded_payload,
              "X-GEMINI-SIGNATURE": signature,
              Accept: "application/json",
              "Content-Type": "text/plain"
            }
          end
          response.body
        end
      end
    end
  end
end
