# frozen_string_literal: true

module Honeymaker
  module Exchanges
    class Kucoin < Exchange
      BASE_URL = "https://api.kucoin.com"

      def get_tickers_info
        with_rescue do
          response = connection.get("/api/v2/symbols")

          response.body["data"].filter_map do |product|
            {
              ticker: product["symbol"],
              base: product["baseCurrency"],
              quote: product["quoteCurrency"],
              minimum_base_size: product["baseMinSize"],
              minimum_quote_size: product["quoteMinSize"],
              maximum_base_size: product["baseMaxSize"],
              maximum_quote_size: product["quoteMaxSize"],
              base_decimals: Utils.decimals(product["baseIncrement"]),
              quote_decimals: Utils.decimals(product["quoteIncrement"]),
              price_decimals: Utils.decimals(product["priceIncrement"]),
              available: product["enableTrading"]
            }
          end
        end
      end

      def get_bid_ask(symbol)
        with_rescue do
          response = connection.get("/api/v1/market/orderbook/level1") do |req|
            req.params = { symbol: symbol }
          end

          data = response.body["data"]
          {
            bid: BigDecimal(data["bestBid"]),
            ask: BigDecimal(data["bestAsk"])
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
