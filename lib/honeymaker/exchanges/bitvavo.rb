# frozen_string_literal: true

module Honeymaker
  module Exchanges
    class Bitvavo < Exchange
      BASE_URL = "https://api.bitvavo.com"

      def get_tickers_info
        with_rescue do
          response = connection.get("/v2/markets")

          response.body.filter_map do |product|
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
              base_decimals: product["quantityDecimals"] || 8,
              quote_decimals: product["notionalDecimals"] || 8,
              price_decimals: count_decimals(product.fetch("tickSize")),
              available: true,
              trading_enabled: product["status"] == "trading"
            }
          end
        end
      end

      def get_bid_ask(symbol)
        with_rescue do
          response = connection.get("/v2/ticker/book") do |req|
            req.params = { market: symbol }
          end

          {
            bid: BigDecimal(response.body["bid"]),
            ask: BigDecimal(response.body["ask"])
          }
        end
      end

      private

      # Bitvavo's tickSize is always a power of ten (e.g. "1.00", "0.0000100"),
      # so the count of significant decimal places is the price precision.
      def count_decimals(value)
        # Strip trailing zeros AND a dangling dot so whole-number ticks like
        # "1.00" -> "1" yield 0 (Ruby's "1.".split(".") would wrongly give ["1"]).
        str = value.to_s.sub(/\.?0+$/, "")
        return 0 unless str.include?(".")

        str.split(".").last.length
      end

      def connection
        @connection ||= build_connection(BASE_URL)
      end
    end
  end
end
