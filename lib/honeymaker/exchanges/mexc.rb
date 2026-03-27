# frozen_string_literal: true

module Honeymaker
  module Exchanges
    class Mexc < Exchange
      BASE_URL = "https://api.mexc.com"

      def get_tickers_info
        with_rescue do
          response = connection.get("/api/v3/exchangeInfo")

          response.body["symbols"].filter_map do |product|
            f = Utils.parse_filters(product["filters"])

            {
              ticker: product["symbol"],
              base: product["baseAsset"],
              quote: product["quoteAsset"],
              minimum_base_size: f[:lot_size]&.[]("minQty"),
              minimum_quote_size: f[:notional]&.[]("minNotional"),
              maximum_base_size: f[:lot_size]&.[]("maxQty"),
              maximum_quote_size: f[:notional]&.[]("maxNotional"),
              base_decimals: f[:lot_size] ? Utils.decimals(f[:lot_size]["stepSize"]) : product["baseAssetPrecision"],
              quote_decimals: product["quoteAssetPrecision"],
              price_decimals: f[:price] ? Utils.decimals(f[:price]["tickSize"]) : product["quotePrecision"],
              available: product["status"] == "TRADING"
            }
          end
        end
      end

      def get_bid_ask(symbol)
        with_rescue do
          response = connection.get("/api/v3/ticker/bookTicker") do |req|
            req.params = { symbol: symbol }
          end

          {
            bid: BigDecimal(response.body["bidPrice"]),
            ask: BigDecimal(response.body["askPrice"])
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
