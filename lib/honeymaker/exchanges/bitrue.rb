# frozen_string_literal: true

module Honeymaker
  module Exchanges
    class Bitrue < Exchange
      BASE_URL = "https://openapi.bitrue.com"

      def get_tickers_info
        with_rescue do
          response = connection.get("/api/v1/exchangeInfo")

          response.body["symbols"].filter_map do |product|
            filters = product["filters"] || []
            price_filter = filters.find { |f| f["filterType"] == "PRICE_FILTER" }
            lot_size_filter = filters.find { |f| f["filterType"] == "LOT_SIZE" }

            {
              ticker: product["symbol"],
              base: product["baseAsset"]&.upcase,
              quote: product["quoteAsset"]&.upcase,
              minimum_base_size: lot_size_filter&.dig("minQty"),
              minimum_quote_size: lot_size_filter&.dig("minVal"),
              maximum_base_size: lot_size_filter&.dig("maxQty"),
              maximum_quote_size: nil,
              base_decimals: if lot_size_filter
                               Utils.decimals(lot_size_filter["stepSize"])
                             else
                               product["baseAssetPrecision"]
                             end,
              quote_decimals: product["quotePrecision"],
              price_decimals: if price_filter
                                Utils.decimals(price_filter["tickSize"])
                              else
                                product["quotePrecision"]
                              end,
              available: product["status"] == "TRADING"
            }
          end
        end
      end

      private

      def connection
        @connection ||= build_connection(BASE_URL)
      end
    end
  end
end
