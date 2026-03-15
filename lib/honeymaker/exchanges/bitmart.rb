# frozen_string_literal: true

module Honeymaker
  module Exchanges
    class BitMart < Exchange
      BASE_URL = "https://api-cloud.bitmart.com"

      def get_tickers_info
        with_rescue do
          response = connection.get("/spot/v1/symbols/details")

          response.body["data"]["symbols"].filter_map do |product|
            {
              ticker: product["symbol"],
              base: product["base_currency"],
              quote: product["quote_currency"],
              minimum_base_size: product["base_min_size"],
              minimum_quote_size: product["min_buy_amount"],
              maximum_base_size: nil,
              maximum_quote_size: nil,
              base_decimals: Utils.decimals(product["base_min_size"]),
              quote_decimals: Utils.decimals(product["quote_increment"]),
              price_decimals: product["price_max_precision"].to_i,
              available: product["trade_status"] == "trading"
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
