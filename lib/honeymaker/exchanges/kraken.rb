# frozen_string_literal: true

module Honeymaker
  module Exchanges
    class Kraken < Exchange
      BASE_URL = "https://api.kraken.com"

      ASSET_BLACKLIST = [
        "COPM" # has the same external_id (ecomi) as OMI
      ].freeze

      # Patterns are unanchored (except regional_restriction) because the consumer may
      # pass a sentence-joined error string. transient_nonce is matched first as it is
      # the more specific/actionable case.
      ERROR_PATTERNS = [
        {
          code: :regional_restriction,
          pattern: /\AEAccount:Invalid permissions:(?<asset>\S+) trading restricted for (?<country>\w+)\.?\z/
        },
        {
          code: :transient_nonce,
          pattern: /EAPI:Invalid nonce/
        },
        {
          code: :transient_unavailable,
          pattern: /EGeneral:Internal error|EService:(?:Unavailable|Busy|Deadline elapsed)/
        }
      ].freeze

      REAL_COSTMIN = {
        "AUD" => 10,
        "CAD" => 5,
        "CHF" => 5,
        "DAI" => 5,
        "ETH" => 0.002,
        "EUR" => 0.5,
        "GBP" => 5,
        "JPY" => 500,
        "PYUSD" => 5,
        "RLUSD" => 5,
        "USD" => 5,
        "USDC" => 5,
        "USDQ" => 5,
        "USDR" => 5,
        "USDT" => 5,
        "XBT" => 0.00005
      }.freeze

      def get_tickers_info
        with_rescue do
          # aclass_base=all, not a bare call: the default response carries only the "currency" class,
          # so Kraken tokenized equities (xStocks) are invisible without it. One request returns both
          # classes and they are disjoint.
          response = connection.get("/0/public/AssetPairs", { aclass_base: "all" })

          error = response.body["error"]
          return Result::Failure.new(*error) if error.is_a?(Array) && error.any?

          # Every tokenized pair is returned TWICE - once under an SPV key (NVDASPVUSD), once under
          # the x key (NVDAxUSD) - sharing one wsname and altname. Currency pairs are never
          # duplicated, so keying by wsname collapses exactly the aliases and nothing else.
          deduped = response.body["result"].each_with_object({}) do |(_, info), acc|
            wsname = info["wsname"]
            next if wsname.nil? || wsname.empty?

            acc[wsname] ||= info
          end

          deduped.filter_map do |wsname, info|
            base, quote = wsname.split("/")

            {
              ticker: info["altname"],
              base: base,
              quote: quote,
              minimum_base_size: info["ordermin"],
              minimum_quote_size: (REAL_COSTMIN[quote] || info["costmin"] || 0).to_s,
              maximum_base_size: nil,
              maximum_quote_size: nil,
              base_decimals: info["lot_decimals"],
              quote_decimals: info["cost_decimals"],
              price_decimals: info["pair_decimals"],
              available: true,
              # Tokenized equities are listed but never tradable through this client: AddOrder needs
              # an asset_class parameter it does not send, and Kraken closes the tokenized order
              # books to EEA clients over the API regardless of that. Listing them anyway is what
              # lets a holding be resolved and valued.
              trading_enabled: if info["aclass_base"] == "tokenized_asset"
                                 false
                               else
                                 info.key?("status") ? info["status"] == "online" : true
                               end
            }
          end
        end
      end

      def get_bid_ask(symbol)
        with_rescue do
          response = connection.get("/0/public/Ticker") do |req|
            req.params = { pair: symbol }
          end

          error = response.body["error"]
          raise StandardError, error.first if error.is_a?(Array) && error.any?

          _key, data = response.body["result"].first
          {
            bid: BigDecimal(data["b"][0]),
            ask: BigDecimal(data["a"][0])
          }
        end
      end

      private

      def connection
        @connection ||= build_connection(BASE_URL)
      end
    end
  end
end
