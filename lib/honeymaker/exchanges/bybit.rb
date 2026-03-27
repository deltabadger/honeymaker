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

          response.body["result"]["list"].filter_map do |product|
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
          end
        end
      end

      def get_bid_ask(symbol)
        with_rescue do
          response = connection.get("/v5/market/tickers") do |req|
            req.params = { category: "spot", symbol: symbol }
          end

          ticker = response.body["result"]["list"].first
          {
            bid: BigDecimal(ticker["bid1Price"]),
            ask: BigDecimal(ticker["ask1Price"])
          }
        end
      end

      private

      def connection
        @connection ||= build_connection(BASE_URL)
      end
    end
  end
end
