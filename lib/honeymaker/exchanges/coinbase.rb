# frozen_string_literal: true

module Honeymaker
  module Exchanges
    class Coinbase < Exchange
      BASE_URL = "https://api.coinbase.com"

      ASSET_BLACKLIST = [
        "RENDER",    # has the same external_id as RNDR
        "ZETACHAIN", # has the same external_id as ZETA
        "WAXL"       # has the same external_id as AXL
      ].freeze

      def get_tickers_info
        with_rescue do
          response = connection.get("/api/v3/brokerage/market/products")

          response.body["products"].map do |product|
            ticker = product["product_id"]
            base, quote = ticker.split("-")
            next if ASSET_BLACKLIST.include?(base)

            base_increment = product["base_increment"]
            quote_increment = product["quote_increment"]
            price_increment = product["price_increment"]

            {
              ticker: ticker,
              base: base,
              quote: quote,
              minimum_base_size: product["base_min_size"],
              minimum_quote_size: product["quote_min_size"],
              maximum_base_size: product["base_max_size"],
              maximum_quote_size: product["quote_max_size"],
              base_decimals: Utils.decimals(base_increment),
              quote_decimals: Utils.decimals(quote_increment),
              price_decimals: Utils.decimals(price_increment),
              available: true
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
