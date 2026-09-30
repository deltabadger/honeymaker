# frozen_string_literal: true

module Honeymaker
  # Rust-backed venue logic. A process picks its backend per exchange once, when honeymaker is
  # required: HONEYMAKER_NATIVE=kraken. With the flag off the extension is never loaded.
  module Native
    # A venue payload whose shape legacy would have tripped over with an incidental NoMethodError
    # or TypeError. Still a StandardError, which is all consumers rescue.
    class ShapeError < StandardError; end

    SUPPORTED = %w[kraken].freeze

    class << self
      def enabled
        @enabled ||= begin
          names = ENV.fetch("HONEYMAKER_NATIVE", "").split(",").map { |name| name.strip.downcase }.reject(&:empty?).uniq
          unsupported = names - SUPPORTED
          unless unsupported.empty?
            raise ArgumentError, "Unsupported HONEYMAKER_NATIVE names: #{unsupported.join(', ')}; supported names: #{SUPPORTED.join(', ')}"
          end
          names.freeze
        end
      end

      def enabled?(name)
        name = name.to_s.strip.downcase
        names = enabled
        SUPPORTED.include?(name) && names.include?(name)
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
