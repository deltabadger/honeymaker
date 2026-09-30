# frozen_string_literal: true

module Honeymaker
  # Rust-backed venue logic. A process picks its backend per exchange once, when honeymaker is
  # required: HONEYMAKER_NATIVE=kraken[,binance]. With the flag off the extension is never loaded.
  module Native
    # A venue payload whose shape legacy would have tripped over with an incidental NoMethodError
    # or TypeError. Still a StandardError, which is all consumers rescue.
    class ShapeError < StandardError; end

    class << self
      def enabled
        @enabled ||= ENV.fetch("HONEYMAKER_NATIVE", "").split(",").map(&:strip).reject(&:empty?).freeze
      end

      def enabled?(name)
        enabled.include?(name.to_s)
      end

      def load!
        return if defined?(Ext)

        begin
          require "honeymaker/#{RUBY_VERSION[/\A\d+\.\d+/]}/honeymaker_native" # fat platform gem
        rescue LoadError
          require "honeymaker/honeymaker_native" # compiled from source / rake compile
        end
      end
    end
  end
end
