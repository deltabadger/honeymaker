# frozen_string_literal: true

module Honeymaker
  module Exchanges
    class Bybit < Exchange
      BASE_URL = "https://api.bybit.com"

      def get_tickers_info
        with_rescue do
          response = connection.get("/v5/market/instruments-info") do |req|
            req.params = { category: "spot" }
          end

          response.body["result"]["list"].map do |product|
            lot_size_filter = product["lotSizeFilter"]
            price_filter = product["priceFilter"]

            {
              ticker: product["symbol"],
              base: product["baseCoin"],
              quote: product["quoteCoin"],
              minimum_base_size: lot_size_filter["minOrderQty"],
              minimum_quote_size: lot_size_filter["minOrderAmt"],
              maximum_base_size: lot_size_filter["maxOrderQty"],
              maximum_quote_size: lot_size_filter["maxOrderAmt"],
              base_decimals: Utils.decimals(lot_size_filter["basePrecision"]),
              quote_decimals: Utils.decimals(lot_size_filter["quotePrecision"]),
              price_decimals: Utils.decimals(price_filter["tickSize"]),
              available: product["status"] == "Trading"
            }
          end.compact
        end
      end

      private

      def connection
        @connection ||= build_connection(BASE_URL)
      end
    end
  end
end
