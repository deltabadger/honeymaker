# frozen_string_literal: true

module Honeymaker
  class Exchange
    OPTIONS = {
      request: {
        open_timeout: 5,
        read_timeout: 30,
        write_timeout: 5
      }
    }.freeze

    ERROR_PATTERNS = [].freeze

    def classify_error(message)
      return nil if message.nil?

      self.class::ERROR_PATTERNS.each do |entry|
        next unless (match = entry[:pattern].match(message))
        return { code: entry[:code], **match.named_captures.transform_keys(&:to_sym) }
      end
      nil
    end

    def get_tickers_info
      raise NotImplementedError, "#{self.class} must implement #get_tickers_info"
    end

    def get_bid_ask(symbol)
      raise NotImplementedError, "#{self.class} must implement #get_bid_ask"
    end

    def get_price(symbol)
      result = get_bid_ask(symbol)
      return result if result.failure?

      Result::Success.new((result.data[:bid] + result.data[:ask]) / 2)
    end

    def tickers_info
      if @tickers_info_cache && @tickers_info_expires_at && @tickers_info_expires_at > Time.now
        return Result::Success.new(@tickers_info_cache)
      end

      result = get_tickers_info
      if result.success?
        @tickers_info_cache = result.data
        @tickers_info_expires_at = Time.now + cache_ttl
      end
      result
    end

    def find_ticker(symbol)
      result = tickers_info
      return result if result.failure?

      ticker = result.data.find { |t| t[:ticker] == symbol }
      ticker ? Result::Success.new(ticker) : Result::Failure.new("Unknown symbol: #{symbol}")
    end

    def symbols
      result = tickers_info
      return result if result.failure?

      Result::Success.new(result.data.map { |t| { base: t[:base], quote: t[:quote] } })
    end

    def cache_ttl
      3600
    end

    private

    def with_rescue
      Result::Success.new(yield)
    rescue Faraday::Error => e
      body = e.respond_to?(:response_body) ? e.response_body : nil
      error_message = (body && !body.empty?) ? body : e.message.to_s
      error_message = "Unknown API error" if error_message.nil? || error_message.empty?
      Result::Failure.new(error_message)
    rescue StandardError => e
      msg = e.message
      Result::Failure.new((msg && !msg.empty?) ? msg : "Unknown error")
    end

    def build_connection(url, content_type_match: nil)
      Faraday.new(url: url, **OPTIONS) do |config|
        config.request :json
        if content_type_match
          config.response :json, content_type: content_type_match
        else
          config.response :json
        end
        config.response :raise_error
        config.adapter :net_http_persistent do |http|
          http.idle_timeout = 100
        end
      end
    end
  end
end
