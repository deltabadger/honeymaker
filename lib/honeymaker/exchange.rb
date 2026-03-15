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

    def get_tickers_info
      raise NotImplementedError, "#{self.class} must implement #get_tickers_info"
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
