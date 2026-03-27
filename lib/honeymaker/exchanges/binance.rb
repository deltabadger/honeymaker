# frozen_string_literal: true

module Honeymaker
  module Exchanges
    class Binance < Exchange
      BASE_URL = "https://api.binance.com"

      def get_tickers_info
        with_rescue do
          response = connection.get("/api/v3/exchangeInfo") do |req|
            req.params = { permissions: "SPOT" }
          end

          response.body["symbols"].filter_map do |product|
            f = Utils.parse_filters(product["filters"])

            {
              ticker: product["symbol"],
              base: product["baseAsset"],
              quote: product["quoteAsset"],
              minimum_base_size: f[:lot_size]["minQty"],
              minimum_quote_size: f[:notional]["minNotional"],
              maximum_base_size: f[:lot_size]["maxQty"],
              maximum_quote_size: f[:notional]["maxNotional"],
              base_decimals: Utils.decimals(f[:lot_size]["stepSize"]),
              quote_decimals: product["quoteAssetPrecision"],
              price_decimals: Utils.decimals(f[:price]["tickSize"]),
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
        @connection ||= build_connection(self.class::BASE_URL)
      end
    end
  end
end
