# frozen_string_literal: true

require "digest"

module Honeymaker
  module Clients
    class KrakenFutures < Client
      URL = "https://futures.kraken.com"

      RATE_LIMITS = { default: 500, orders: 500 }.freeze

      def get_accounts
        get_private("/derivatives/api/v3/accounts")
      end

      def get_fills(last_fill_time: nil)
        get_private("/derivatives/api/v3/fills", { lastFillTime: last_fill_time })
      end

      def get_open_positions
        get_private("/derivatives/api/v3/openpositions")
      end

      def historical_funding_rates(symbol:)
        get_public("/derivatives/api/v3/historicalfundingrates", { symbol: symbol })
      end

      private

      def validate_trading_credentials
        result = get_accounts
        return Result::Failure.new("Invalid trading credentials") if result.failure?
        Result::Success.new(true)
      end

      def validate_read_credentials
        validate_trading_credentials
      end

      def get_public(path, params = {})
        with_rescue do
          response = connection.get do |req|
            req.url path
            req.params = params.compact
          end
          response.body
        end
      end

      def get_private(path, params = {})
        with_rescue do
          params = params.compact
          query_string = params.empty? ? "" : Faraday::Utils.build_query(params)
          nonce = timestamp_ms.to_s

          post_data = query_string
          hash_input = "#{post_data}#{nonce}#{path}"
          sha256_hash = Digest::SHA256.digest(hash_input)
          decoded_secret = Base64.decode64(@api_secret)
          hmac = OpenSSL::HMAC.digest("sha512", decoded_secret, sha256_hash)
          authent = Base64.strict_encode64(hmac)

          response = connection.get do |req|
            req.url path
            req.headers = {
              "APIKey": @api_key,
              "Authent": authent,
              "Nonce": nonce,
              Accept: "application/json"
            }
            req.params = params
          end
          response.body
        end
      end
    end
  end
end
