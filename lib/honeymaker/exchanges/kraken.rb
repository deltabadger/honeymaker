# frozen_string_literal: true

module Honeymaker
  module Exchanges
    class Kraken < Exchange
      BASE_URL = "https://api.kraken.com"

      ASSET_BLACKLIST = [
        "COPM" # has the same external_id (ecomi) as OMI
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
          response = connection.get("/0/public/AssetPairs")

          error = response.body["error"]
          return Result::Failure.new(*error) if error.is_a?(Array) && error.any?

          response.body["result"].filter_map do |_, info|
            wsname = info["wsname"]
            next unless wsname && !wsname.empty?

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
