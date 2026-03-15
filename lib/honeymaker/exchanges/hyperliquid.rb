# frozen_string_literal: true

module Honeymaker
  module Exchanges
    class Hyperliquid < Exchange
      BASE_URL = "https://api.hyperliquid.xyz"

      def get_tickers_info
        with_rescue do
          response = connection.post("/info") do |req|
            req.body = { type: "spotMeta" }.to_json
          end

          tokens = response.body["tokens"]
          universe = response.body["universe"]
          token_map = tokens.each_with_object({}) { |t, h| h[t["index"]] = t }

          universe.filter_map do |pair|
            base_token = token_map[pair["tokens"][0]]
            quote_token = token_map[pair["tokens"][1]]
            next unless base_token && quote_token

            {
              ticker: pair["name"],
              base: base_token["name"],
              quote: quote_token["name"],
              minimum_base_size: nil,
              minimum_quote_size: nil,
              maximum_base_size: nil,
              maximum_quote_size: nil,
              base_decimals: base_token["szDecimals"] || 0,
              quote_decimals: 2,
              price_decimals: 5,
              available: true
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
