# frozen_string_literal: true

module Honeymaker
  module Exchanges
    class Bitget < Exchange
      BASE_URL = "https://api.bitget.com"

      def get_tickers_info
        with_rescue do
          response = connection.get("/api/v2/spot/public/symbols")

          response.body["data"].map do |product|
            {
              ticker: product["symbol"],
              base: product["baseCoin"],
              quote: product["quoteCoin"],
              minimum_base_size: product["minTradeAmount"],
              minimum_quote_size: product["minTradeUSDT"],
              maximum_base_size: product["maxTradeAmount"],
              maximum_quote_size: nil,
              base_decimals: product["quantityPrecision"].to_i,
              quote_decimals: product["quotePrecision"].to_i,
              price_decimals: product["pricePrecision"].to_i,
              available: product["status"] == "online"
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
