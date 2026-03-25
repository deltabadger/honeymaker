# frozen_string_literal: true

require "jwt"

module Honeymaker
  module Clients
    class Coinbase < Client
      URL = "https://api.coinbase.com"
      RATE_LIMITS = { default: 100, orders: 100 }.freeze

      def initialize(api_key: nil, api_secret: nil, proxy: nil, logger: nil)
        super
        @api_secret = @api_secret&.gsub('\n', "\n")
      end

      def get_order(order_id:)
        result = get("/api/v3/brokerage/orders/historical/#{order_id}")
        return result if result.failure?

        raw = result.data.is_a?(Hash) && result.data.key?("order") ? result.data["order"] : result.data
        Result::Success.new(normalize_order(order_id, raw))
      end

      def list_orders(order_ids: nil, product_ids: nil, product_type: nil, order_status: nil,
                      time_in_forces: nil, order_types: nil, order_side: nil, start_date: nil,
                      end_date: nil, order_placement_source: nil, contract_expiry_type: nil,
                      asset_filters: nil, limit: nil, cursor: nil, sort_by: nil)
        with_rescue do
          response = connection.get do |req|
            req.url "/api/v3/brokerage/orders/historical/batch"
            req.headers = auth_headers(req)
            req.params = {
              order_ids: order_ids, product_ids: product_ids, product_type: product_type,
              order_status: order_status, time_in_forces: time_in_forces,
              order_types: order_types, order_side: order_side,
              start_date: start_date, end_date: end_date,
              order_placement_source: order_placement_source,
              contract_expiry_type: contract_expiry_type,
              asset_filters: asset_filters, limit: limit, cursor: cursor, sort_by: sort_by
            }.compact
            req.options.params_encoder = Faraday::FlatParamsEncoder
          end
          response.body
        end
      end

      def create_order(client_order_id:, product_id:, side:, order_configuration:)
        result = post("/api/v3/brokerage/orders", {
          client_order_id: client_order_id, product_id: product_id,
          side: side, order_configuration: order_configuration
        })
        return result if result.failure?

        raw = result.data
        if raw["success"] == false
          error_msg = raw.dig("error_response", "message") || "Order creation failed"
          return Result::Failure.new(error_msg)
        end

        order_id = raw.dig("success_response", "order_id")
        Result::Success.new({ order_id: order_id, raw: raw })
      end

      def cancel_orders(order_ids:)
        post("/api/v3/brokerage/orders/batch_cancel", { order_ids: order_ids })
      end

      def list_public_products(limit: nil, offset: nil, product_type: nil, product_ids: nil,
                               contract_expiry_type: nil, expiring_contract_status: nil,
                               get_tradability_status: nil, get_all_products: nil)
        get("/api/v3/brokerage/market/products", {
          limit: limit, offset: offset, product_type: product_type, product_ids: product_ids,
          contract_expiry_type: contract_expiry_type,
          expiring_contract_status: expiring_contract_status,
          get_tradability_status: get_tradability_status, get_all_products: get_all_products
        })
      end

      def get_public_product(product_id:, get_tradability_status: nil)
        get("/api/v3/brokerage/market/products/#{product_id}", { get_tradability_status: get_tradability_status })
      end

      def get_public_product_book(product_id:, limit: nil, aggregation_price_increment: nil)
        with_rescue do
          response = connection.get do |req|
            req.url "/api/v3/brokerage/market/product_book"
            req.headers = auth_headers(req)
            req.params = {
              product_id: product_id, limit: limit,
              aggregation_price_increment: aggregation_price_increment
            }.compact
            req.options.params_encoder = Faraday::FlatParamsEncoder
          end
          response.body
        end
      end

      def get_public_product_candles(product_id:, start_time:, end_time:, granularity:, limit: nil)
        get("/api/v3/brokerage/market/products/#{product_id}/candles", {
          start: start_time, end: end_time, granularity: granularity, limit: limit
        })
      end

      def get_api_key_permissions
        get("/api/v3/brokerage/key_permissions")
      end

      def list_accounts
        get("/api/v3/brokerage/accounts")
      end

      def list_portfolios
        get("/api/v3/brokerage/portfolios")
      end

      def get_balances(portfolio_uuid: nil)
        unless portfolio_uuid
          portfolios_result = list_portfolios
          return portfolios_result if portfolios_result.failure?

          portfolio = Array(portfolios_result.data["portfolios"]).first
          return Result::Failure.new("No portfolios found") unless portfolio
          portfolio_uuid = portfolio["uuid"]
        end

        result = get_portfolio_breakdown(portfolio_uuid: portfolio_uuid)
        return result if result.failure?

        balances = {}
        positions = result.data.dig("breakdown", "spot_positions") || []
        positions.each do |position|
          symbol = position["asset"]
          next unless symbol

          free = BigDecimal((position["available_to_trade_crypto"] || "0").to_s)
          total = BigDecimal((position["total_balance_crypto"] || "0").to_s)
          locked = total - free
          next if free.zero? && locked.zero?
          balances[symbol] = { free: free, locked: locked }
        end

        Result::Success.new(balances)
      end

      def get_portfolio_breakdown(portfolio_uuid:, currency: nil)
        get("/api/v3/brokerage/portfolios/#{portfolio_uuid}", { currency: currency })
      end

      def send_money(account_id:, to:, amount:, currency:, idem: nil)
        post("/v2/accounts/#{account_id}/transactions", {
          type: "send", to: to, amount: amount, currency: currency, idem: idem
        })
      end

      def list_fills(product_id: nil, order_id: nil, start_sequence_timestamp: nil,
                     end_sequence_timestamp: nil, limit: nil, cursor: nil)
        with_rescue do
          response = connection.get do |req|
            req.url "/api/v3/brokerage/orders/historical/fills"
            req.headers = auth_headers(req)
            req.params = {
              product_id: product_id, order_id: order_id,
              start_sequence_timestamp: start_sequence_timestamp,
              end_sequence_timestamp: end_sequence_timestamp,
              limit: limit, cursor: cursor
            }.compact
            req.options.params_encoder = Faraday::FlatParamsEncoder
          end
          response.body
        end
      end

      def list_transactions(account_id:, limit: nil, starting_after: nil)
        get("/v2/accounts/#{account_id}/transactions", { limit: limit, starting_after: starting_after })
      end

      private

      def get(path, params = {})
        with_rescue do
          response = connection.get do |req|
            req.url path
            req.headers = auth_headers(req)
            req.params = params.compact
          end
          response.body
        end
      end

      def post(path, body = {})
        with_rescue do
          response = connection.post do |req|
            req.url path
            req.headers = auth_headers(req)
            req.body = body.compact
          end
          response.body
        end
      end

      def normalize_order(order_id, raw)
        order_type = parse_order_type(raw["order_type"])
        side = raw["side"]&.downcase&.to_sym
        status = parse_order_status(raw["status"])

        price = BigDecimal((raw["average_filled_price"] || "0").to_s)

        case order_type
        when :limit
          config = (raw["order_configuration"] || {})["limit_limit_gtc"] || {}
          amount = config["base_size"] ? BigDecimal(config["base_size"].to_s) : nil
          quote_amount = config["quote_size"] ? BigDecimal(config["quote_size"].to_s) : nil
          price = BigDecimal(config["limit_price"].to_s) if price.zero? && config["limit_price"]
        when :market
          config = (raw["order_configuration"] || {})["market_market_ioc"] || {}
          amount = config["base_size"] ? BigDecimal(config["base_size"].to_s) : nil
          quote_amount = config["quote_size"] ? BigDecimal(config["quote_size"].to_s) : nil
        else
          amount = nil
          quote_amount = nil
        end

        price = nil if price.zero?

        amount_exec = BigDecimal((raw["filled_size"] || "0").to_s)
        total_value = BigDecimal((raw["total_value_after_fees"] || "0").to_s)
        outstanding = BigDecimal((raw["outstanding_hold_amount"] || "0").to_s)
        quote_amount_exec = total_value - outstanding

        {
          order_id: order_id,
          status: status,
          side: side,
          order_type: order_type,
          price: price,
          amount: amount,
          quote_amount: quote_amount,
          amount_exec: amount_exec,
          quote_amount_exec: quote_amount_exec,
          raw: raw
        }
      end

      def parse_order_type(type)
        case type
        when "MARKET" then :market
        when "LIMIT" then :limit
        else :unknown
        end
      end

      def parse_order_status(status)
        case status
        when "PENDING", "UNKNOWN_ORDER_STATUS" then :unknown
        when "OPEN" then :open
        when "FILLED" then :closed
        when "CANCELLED", "EXPIRED" then :cancelled
        when "FAILED" then :failed
        else :unknown
        end
      end

      def validate_trading_credentials
        # List accounts — if it works, the key has trading access
        result = list_accounts
        return Result::Failure.new("Invalid trading credentials") if result.failure?
        Result::Success.new(true)
      end

      def validate_read_credentials
        result = get_api_key_permissions
        return Result::Failure.new("Invalid read credentials") if result.failure?
        Result::Success.new(true)
      end

      def auth_headers(req)
        return unauthenticated_headers unless authenticated?

        timestamp = Time.now.utc.to_i
        method = req.http_method.to_s.upcase
        request_host = URI(URL).host
        request_path = req.path

        jwt_payload = {
          sub: @api_key,
          iss: "coinbase-cloud",
          nbf: timestamp,
          exp: timestamp + 120,
          uri: "#{method} #{request_host}#{request_path}"
        }

        signing_key = ecdsa_key? ? ecdsa_signing_key : ed25519_signing_key
        return unauthenticated_headers if signing_key.nil?

        algorithm = ecdsa_key? ? "ES256" : "EdDSA"
        jwt = JWT.encode(jwt_payload, signing_key, algorithm, { kid: @api_key, nonce: SecureRandom.hex })

        { Authorization: "Bearer #{jwt}", Accept: "application/json", "Content-Type": "application/json" }
      end

      def unauthenticated_headers
        { Accept: "application/json", "Content-Type": "application/json" }
      end

      def ecdsa_key?
        @api_secret&.start_with?("-----BEGIN EC PRIVATE KEY-----")
      end

      def ecdsa_signing_key
        OpenSSL::PKey::EC.new(@api_secret)
      rescue OpenSSL::PKey::ECError
        nil
      end

      def ed25519_signing_key
        require "rbnacl"
        decoded_key = Base64.decode64(@api_secret)
        seed = decoded_key[0...32]
        RbNaCl::Signatures::Ed25519::SigningKey.new(seed)
      rescue LoadError, RbNaCl::LengthError
        nil
      end
    end
  end
end
