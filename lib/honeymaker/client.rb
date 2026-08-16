# frozen_string_literal: true

require "openssl"
require "base64"
require "securerandom"
require "bigdecimal"

module Honeymaker
  class Client
    OPTIONS = {
      request: {
        open_timeout: 5,
        read_timeout: 30,
        write_timeout: 10
      }
    }.freeze

    RATE_LIMITS = {
      default: 100,
      orders: 100
    }.freeze

    attr_reader :api_key, :api_secret

    def initialize(api_key: nil, api_secret: nil, proxy: nil, logger: nil)
      @api_key = api_key
      @api_secret = api_secret
      @proxy = proxy
      @logger = logger
    end

    def self.rate_limits
      self::RATE_LIMITS
    end

    def get_balances
      raise NotImplementedError, "#{self.class} must implement #get_balances"
    end

    def validate(type = :trading)
      return Result::Failure.new("No credentials provided") unless authenticated?

      case type
      when :trading then validate_trading_credentials
      when :read then validate_read_credentials
      else raise Error, "Unknown validation type: #{type}. Use :trading or :read"
      end
    rescue Error
      raise
    rescue StandardError => e
      Result::Failure.new(e.message)
    end

    private

    def validate_trading_credentials
      raise NotImplementedError, "#{self.class} must implement #validate_trading_credentials"
    end

    def validate_read_credentials
      raise NotImplementedError, "#{self.class} must implement #validate_read_credentials"
    end

    def with_rescue
      Result::Success.new(yield)
    rescue Faraday::Error => e
      body = e.respond_to?(:response_body) ? e.response_body : nil
      error_message = (body && !body.empty?) ? body : e.message.to_s
      error_message = "Unknown API error" if error_message.nil? || error_message.empty?
      status = e.respond_to?(:response_status) ? e.response_status : nil
      Result::Failure.new(error_message, data: { status: status })
    rescue StandardError => e
      # NOT an exchange error — a bug here, in a vendor gem, or in the caller, and it arrives in the
      # same Result::Failure as a genuine venue rejection. Callers classify that text to decide "out
      # of funds" / "bad key" / "safe to retry", so an unlabelled TypeError gets attributed to the
      # exchange: a hyperliquid-rb signing crash sat in production order history for three months
      # reading exactly like a venue rejection. Name the class so the true source is unmistakable,
      # and flag it so a caller can refuse to classify it as the venue's at all.
      #
      # The class is a PREFIX, not a replacement: the network failures that also land here
      # (Net::ReadTimeout, execution expired, connection refused) are matched by substring for
      # transient retry, and those matches must keep working.
      msg = e.message
      labelled = (msg && !msg.empty?) ? "#{e.class}: #{msg}" : e.class.to_s
      Result::Failure.new(labelled, data: { client_error: true })
    end

    # A business error the exchange returned inside an HTTP-200 envelope (KuCoin's non-"200000"
    # code, Bitget's non-"00000"). Keep the exchange's own code and message: callers classify on
    # this text to tell insufficient funds from a bad key from a stale timestamp, so collapsing it
    # to a bare constant silently disables every one of those checks and leaves the operator with
    # an unactionable log line. Falls back to the constant only when the body carries no detail.
    def api_error(exchange, body)
      detail = body.is_a?(Hash) ? [body["code"], body["msg"] || body["message"]] : []
      detail = detail.compact.map(&:to_s).reject(&:empty?).join(": ")
      Result::Failure.new(detail.empty? ? "#{exchange} API error" : "#{exchange} API error #{detail}")
    end

    def connection
      @connection ||= build_client_connection(self.class::URL)
    end

    def build_client_connection(url, content_type_match: nil)
      Faraday.new(url: url, **OPTIONS) do |config|
        config.proxy = @proxy if @proxy
        config.request :json
        if content_type_match
          config.response :json, content_type: content_type_match
        else
          config.response :json
        end
        config.response :raise_error
        config.response :logger, @logger, headers: false, bodies: false, log_level: :debug if @logger
        config.adapter :net_http_persistent do |http|
          http.idle_timeout = 100
        end
      end
    end

    def authenticated?
      @api_key && !@api_key.empty? && @api_secret && !@api_secret.empty?
    end

    def timestamp_ms
      (Time.now.utc.to_f * 1_000).to_i
    end

    def hmac_sha256(secret, data)
      OpenSSL::HMAC.hexdigest("sha256", secret, data)
    end
  end
end
