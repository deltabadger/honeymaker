# frozen_string_literal: true

module Honeymaker
  module Exchanges
    class Gemini < Exchange
      BASE_URL = "https://api.gemini.com"

      def get_tickers_info
        with_rescue do
          symbols_response = connection.get("/v1/symbols")
          symbols = symbols_response.body

          symbols.filter_map do |symbol|
            detail = connection.get("/v1/symbols/details/#{symbol}").body

            tick_size = detail["tick_size"]&.to_s || "0.01"
            quote_increment = detail["quote_increment"]&.to_s || "0.01"

            {
              ticker: symbol.upcase,
              base: detail["base_currency"].upcase,
              quote: detail["quote_currency"].upcase,
              minimum_base_size: detail["min_order_size"],
              minimum_quote_size: "0",
              maximum_base_size: nil,
              maximum_quote_size: nil,
              base_decimals: Utils.decimals(tick_size),
              quote_decimals: Utils.decimals(quote_increment),
              price_decimals: Utils.decimals(quote_increment),
              available: detail["status"] == "open"
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
