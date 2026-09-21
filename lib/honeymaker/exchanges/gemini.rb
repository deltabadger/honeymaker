# frozen_string_literal: true

module Honeymaker
  module Exchanges
    class Gemini < Exchange
      BASE_URL = "https://api.gemini.com"

      # Gemini has no bulk symbol-details endpoint, so the catalogue is one request per symbol --
      # ~350 of them against a public limit of 120/min. Unpaced they ran at ~208/min, and a single
      # dropped connection failed the whole catalogue: the adapter retries nothing on its own.
      REQUEST_INTERVAL = 0.5
      REQUEST_ATTEMPTS = 3
      TRANSIENT_ERRORS = [
        Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::RequestTimeoutError,
        Faraday::TooManyRequestsError, Faraday::ServerError
      ].freeze

      def get_tickers_info
        with_rescue do
          symbols = catalogue_get("/v1/symbols")

          tickers = symbols.filter_map do |symbol|
            # A symbol that still fails raises, failing the WHOLE catalogue. Never skip it: callers
            # read a pair missing from the catalogue as delisted, and data-api revokes it.
            detail = catalogue_get("/v1/symbols/details/#{symbol}")
            next unless spot?(symbol, detail)

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
              available: true,
              trading_enabled: detail["status"] == "open"
            }
          end
          reject_shared_pairs!(tickers)
        end
      end

      def get_bid_ask(symbol)
        with_rescue do
          response = connection.get("/v1/pubticker/#{symbol.downcase}")

          {
            bid: BigDecimal(response.body["bid"]),
            ask: BigDecimal(response.body["ask"])
          }
        end
      end

      private

      def connection
        @connection ||= build_connection(BASE_URL)
      end

      # Gemini lists perpetual swaps beside spot, under the same base and quote (BTCGUSDPERP is
      # BTC/GUSD, product_type "swap"), so only product_type tells them apart. An instrument without
      # one is not assumed to be spot: the catalogue fails and callers keep the one they have.
      def spot?(symbol, detail)
        product_type = detail["product_type"]
        raise Error, "Gemini #{symbol}: no product_type in its details" unless product_type.is_a?(String)

        product_type == "spot"
      end

      # One pair, one instrument. Two would leave callers to pick one by list order.
      def reject_shared_pairs!(tickers)
        shared = tickers.group_by { |t| "#{t[:base]}/#{t[:quote]}" }.find { |_, group| group.size > 1 }
        return tickers unless shared

        pair, group = shared
        raise Error, "Gemini #{pair} is claimed by #{group.map { |t| t[:ticker] }.join(' and ')}"
      end

      def catalogue_get(path)
        attempt = 1
        begin
          sleep(REQUEST_INTERVAL)
          connection.get(path).body
        rescue *TRANSIENT_ERRORS
          raise if attempt >= REQUEST_ATTEMPTS

          sleep(2**attempt)
          attempt += 1
          retry
        end
      end
    end
  end
end
