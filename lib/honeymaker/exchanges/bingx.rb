# frozen_string_literal: true

module Honeymaker
  module Exchanges
    class BingX < Exchange
      BASE_URL = "https://open-api.bingx.com"

      def get_tickers_info
        with_rescue do
          response = connection.get("/openApi/spot/v1/common/symbols")

          response.body["data"]["symbols"].filter_map do |product|
            ticker = product["symbol"]
            parts = ticker.split("-")
            next unless parts.size == 2

            {
              ticker: ticker,
              base: parts[0],
              quote: parts[1],
              minimum_base_size: product["minQty"]&.to_s,
              minimum_quote_size: product["minNotional"]&.to_s,
              maximum_base_size: product["maxQty"]&.to_s,
              maximum_quote_size: product["maxNotional"]&.to_s,
              base_decimals: Utils.decimals(product["stepSize"]),
              quote_decimals: Utils.decimals(product["tickSize"]),
              price_decimals: Utils.decimals(product["tickSize"]),
              available: product["status"].to_i == 1
            }
          end
        end
      end

      private

      def connection
        @connection ||= build_connection(BASE_URL, content_type_match: //)
      end
    end
  end
end
