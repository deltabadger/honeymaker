# frozen_string_literal: true

require "bigdecimal/util"

module Honeymaker
  module Exchanges
    class Bitget < Exchange
      BASE_URL = "https://api.bitget.com"

      def get_tickers_info
        with_rescue do
          response = connection.get("/api/v2/spot/public/symbols")
          products = response.body["data"]
          prices = products.any? { |p| p["quoteCoin"] != "USDT" } ? usdt_prices : {}

          products.filter_map do |product|
            {
              ticker: product["symbol"],
              base: product["baseCoin"],
              quote: product["quoteCoin"],
              minimum_base_size: product["minTradeAmount"],
              minimum_quote_size: quote_minimum(product["quoteCoin"], product["minTradeUSDT"], prices),
              maximum_base_size: product["maxTradeAmount"],
              maximum_quote_size: nil,
              base_decimals: product["quantityPrecision"].to_i,
              quote_decimals: product["quotePrecision"].to_i,
              price_decimals: product["pricePrecision"].to_i,
              available: true,
              trading_enabled: product["status"] == "online"
            }
          end
        end
      end

      def get_bid_ask(symbol)
        with_rescue do
          response = connection.get("/api/v2/spot/market/tickers") do |req|
            req.params = { symbol: symbol }
          end

          ticker = response.body["data"].first
          {
            bid: BigDecimal(ticker["bestBid"]),
            ask: BigDecimal(ticker["bestAsk"])
          }
        end
      end

      private

      # minTradeUSDT is a USDT figure on every pair, whatever its quote
      # (https://www.bitget.com/docs/catalog/classic-spot-market/classic-spot-market#get-symbol-info), so
      # on ETHBTC its 1 meant a 1 BTC minimum. Converted at the quote's own USDT price (never the
      # traded pair's); with no price to convert at, the minimum is left to the venue (0) rather than
      # guessed. Same rule as deltabadger's Exchanges::Bitget#quote_minimum.
      def quote_minimum(quote, usdt_minimum, prices)
        minimum = usdt_minimum.to_s.to_d
        return usdt_minimum if quote == "USDT" || minimum.zero?

        if (price = prices["#{quote}USDT"].to_d).positive?
          (minimum / price).to_s("F")
        elsif (price = prices["USDT#{quote}"].to_d).positive?
          (minimum * price).to_s("F")
        else
          "0"
        end
      end

      # symbol => lastPr for the whole market; {} when the read fails, so conversions fall back to 0.
      def usdt_prices
        connection.get("/api/v2/spot/market/tickers").body["data"].to_h { |t| [t["symbol"], t["lastPr"]] }
      rescue StandardError
        {}
      end

      def connection
        @connection ||= build_connection(BASE_URL)
      end
    end
  end
end
