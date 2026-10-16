# frozen_string_literal: true

module Honeymaker
  module Exchanges
    class Coinbase < Exchange
      BASE_URL = "https://api.coinbase.com"

      ASSET_BLACKLIST = [
        "RNDR",      # delisted; has the same external_id as RENDER
        "ZETACHAIN", # has the same external_id as ZETA
        "WAXL"       # has the same external_id as AXL
      ].freeze

      def get_tickers_info
        with_rescue do
          response = connection.get("/api/v3/brokerage/market/products")

          response.body["products"].filter_map do |product|
            ticker = product["product_id"]
            base, quote = ticker.split("-")
            next if ASSET_BLACKLIST.include?(base)

            {
              ticker: ticker,
              base: base,
              quote: quote,
              minimum_base_size: product["base_min_size"],
              minimum_quote_size: product["quote_min_size"],
              maximum_base_size: product["base_max_size"],
              maximum_quote_size: product["quote_max_size"],
              base_decimals: Utils.decimals(product["base_increment"]),
              quote_decimals: Utils.decimals(product["quote_increment"]),
              price_decimals: Utils.decimals(product["price_increment"]),
              available: true,
              trading_enabled: trading_enabled?(product)
            }
          end
        end
      end

      def get_bid_ask(symbol)
        with_rescue do
          response = connection.get("/api/v3/brokerage/market/products/#{symbol}")

          {
            bid: BigDecimal(response.body["bid"]),
            ask: BigDecimal(response.body["ask"])
          }
        end
      end

      private

      # Coinbase only signals problems explicitly: a `trading_disabled`, `is_disabled`, `limit_only`
      # or `cancel_only` flag, or a non-"online" `status`. Absent any signal, treat the pair as
      # enabled. limit_only is reported as not tradable, like Kraken's limit_only status.
      def trading_enabled?(product)
        return false if %w[trading_disabled is_disabled limit_only cancel_only].any? { |flag| product[flag] == true }
        return false if product.key?("status") && product["status"] != "online"

        true
      end

      def connection
        @connection ||= build_connection(BASE_URL)
      end
    end
  end
end
