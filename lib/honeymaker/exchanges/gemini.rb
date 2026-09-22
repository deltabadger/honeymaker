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

      # A symbol still failing after its retries is usually the venue or the connection, not the
      # instrument, and each costs up to ~100 s. Past this many in one run the venue itself is down, so
      # the whole catalogue fails, as any failure did before.
      # ponytail: flat per-run budget; raise it if a rollout ever 5xxs a bigger family than this.
      NO_ANSWER_LIMIT = 10

      # /v1/symbols says what Gemini lists; the details only describe it. A listed symbol whose details
      # cannot be read this run is SET ASIDE: left out of the catalogue and named in
      # #unreadable_symbols, which callers must read as "unknown", never as delisted. Gemini lists new
      # symbols before it can describe them (details/gramsgd answered 400 InvalidSymbol for hours on
      # 2026-09-22), and failing the whole catalogue for that one left every Gemini pair without a
      # verdict.
      def get_tickers_info
        @unreadable_symbols = {}
        with_rescue do
          symbols = catalogue_get("/v1/symbols")
          no_answers = 0

          tickers = symbols.filter_map do |symbol|
            describe(symbol, catalogue_get("/v1/symbols/details/#{symbol}"))
          rescue *TRANSIENT_ERRORS => e
            raise if (no_answers += 1) >= NO_ANSWER_LIMIT

            set_aside(symbol, e)
          rescue StandardError => e
            set_aside(symbol, e)
          end
          tickers = set_aside_shared_pairs(tickers)
          if tickers.empty? && @unreadable_symbols.any?
            raise Error, "Gemini: no symbol could be read, e.g. #{@unreadable_symbols.first.join(': ')}"
          end

          tickers
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

      def describe(symbol, detail)
        return unless spot?(symbol, detail)

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

      # Gemini lists perpetual swaps beside spot, under the same base and quote (BTCGUSDPERP is
      # BTC/GUSD, product_type "swap"), so only product_type tells them apart. An instrument without
      # one is not assumed to be spot: it is set aside. So is a body that is not an object -- JSON
      # served as text/plain arrives as a String, and String#[] finds "product_type" inside it.
      def spot?(symbol, detail)
        raise Error, "Gemini #{symbol}: details are not an object" unless detail.is_a?(Hash)

        product_type = detail["product_type"]
        raise Error, "Gemini #{symbol}: no product_type in its details" unless product_type.is_a?(String) && !product_type.empty?
        # A missing status would otherwise read as "not open" and revoke the pair.
        raise Error, "Gemini #{symbol}: no status in its details" unless detail["status"].is_a?(String)

        product_type == "spot"
      end

      # One pair, one instrument. Two would leave callers to pick one by list order, so neither is
      # picked: both are set aside until Gemini lists only one.
      def set_aside_shared_pairs(tickers)
        shared = tickers.group_by { |t| [t[:base], t[:quote]] }.values.reject(&:one?)
        shared.each do |group|
          claim = "Gemini #{group.first[:base]}/#{group.first[:quote]} is claimed by #{group.map { |t| t[:ticker] }.join(' and ')}"
          group.each { |t| @unreadable_symbols[t[:ticker]] = claim }
        end
        tickers - shared.flatten
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
