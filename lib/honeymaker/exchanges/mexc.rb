# frozen_string_literal: true

module Honeymaker
  module Exchanges
    class Mexc < Exchange
      BASE_URL = "https://api.mexc.com"

      def get_tickers_info
        with_rescue do
          response = connection.get("/api/v3/exchangeInfo")

          response.body["symbols"].map do |product|
            ticker = product["symbol"]
            status = product["status"]

            filters = product["filters"]
            price_filter = filters.find { |f| f["filterType"] == "PRICE_FILTER" }
            lot_size_filter = filters.find { |f| f["filterType"] == "LOT_SIZE" }
            notional_filter = filters.find { |f| %w[NOTIONAL MIN_NOTIONAL].include?(f["filterType"]) }

            {
              ticker: ticker,
              base: product["baseAsset"],
              quote: product["quoteAsset"],
              minimum_base_size: lot_size_filter&.[]("minQty"),
              minimum_quote_size: notional_filter&.[]("minNotional"),
              maximum_base_size: lot_size_filter&.[]("maxQty"),
              maximum_quote_size: notional_filter&.[]("maxNotional"),
              base_decimals: lot_size_filter ? Utils.decimals(lot_size_filter["stepSize"]) : product["baseAssetPrecision"],
              quote_decimals: product["quoteAssetPrecision"],
              price_decimals: price_filter ? Utils.decimals(price_filter["tickSize"]) : product["quotePrecision"],
              available: status == "TRADING"
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
