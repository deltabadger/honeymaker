# frozen_string_literal: true

module Honeymaker
  module Exchanges
    class Bitvavo < Exchange
      BASE_URL = "https://api.bitvavo.com"

      def get_tickers_info
        with_rescue do
          response = connection.get("/v2/markets")

          response.body.map do |product|
            market = product["market"]
            base, quote = market.split("-")

            {
              ticker: market,
              base: base,
              quote: quote,
              minimum_base_size: product["minOrderInBaseAsset"],
              minimum_quote_size: product["minOrderInQuoteAsset"],
              maximum_base_size: nil,
              maximum_quote_size: nil,
              base_decimals: product["pricePrecision"] || 8,
              quote_decimals: product["pricePrecision"] || 8,
              price_decimals: product["pricePrecision"] || 8,
              available: product["status"] == "trading"
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
