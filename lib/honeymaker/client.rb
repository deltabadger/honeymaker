# frozen_string_literal: true

require "openssl"
require "base64"
require "securerandom"

module Honeymaker
  class Client
    OPTIONS = {
      request: {
        open_timeout: 5,
        read_timeout: 30,
        write_timeout: 10
      }
    }.freeze

    attr_reader :api_key, :api_secret

    def initialize(api_key: nil, api_secret: nil, proxy: nil, logger: nil)
      @api_key = api_key
      @api_secret = api_secret
      @proxy = proxy
      @logger = logger
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
      msg = e.message
      Result::Failure.new((msg && !msg.empty?) ? msg : "Unknown error")
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
