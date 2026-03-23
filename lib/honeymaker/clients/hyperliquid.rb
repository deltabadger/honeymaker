# frozen_string_literal: true

module Honeymaker
  module Clients
    class Hyperliquid < Client
      URL = "https://api.hyperliquid.xyz"

      def spot_meta
        post_info({ type: "spotMeta" })
      end

      def spot_meta_and_asset_ctxs
        post_info({ type: "spotMetaAndAssetCtxs" })
      end

      def spot_clearinghouse_state(user:)
        post_info({ type: "spotClearinghouseState", user: user })
      end

      def order_status(user:, oid:)
        post_info({ type: "orderStatus", user: user, oid: oid })
      end

      def open_orders(user:)
        post_info({ type: "openOrders", user: user })
      end

      private

      def validate_trading_credentials
        return Result::Failure.new("No wallet address provided") unless @api_key
        result = open_orders(user: @api_key)
        result.success? ? Result::Success.new(true) : Result::Failure.new("Invalid credentials")
      end

      def validate_read_credentials
        validate_trading_credentials
      end

      def post_info(body)
        with_rescue do
          response = connection.post do |req|
            req.url "/info"
            req.headers = { Accept: "application/json", "Content-Type": "application/json" }
            req.body = body.to_json
          end
          response.body
        end
      end
    end
  end
end
