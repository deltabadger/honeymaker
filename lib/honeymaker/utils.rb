# frozen_string_literal: true

module Honeymaker
  module Utils
    def self.decimals(num)
      return 0 if num.nil?
      str = num.to_s.sub(/\.?0+$/, "")
      return 0 unless str.include?(".")
      str.split(".").last.length
    end

    # The exception classes behind an error, outermost first, following both Faraday's
    # #wrapped_exception and Ruby's #cause (adapters nest them differently), each named once.
    # Reported on a transport failure so a caller can tell where it happened; see Client#with_rescue.
    def self.error_chain(error, limit: 10)
      names = []
      seen = {}.compare_by_identity # exceptions, not classes: adapters re-wrap in the same class
      queue = [error]
      until queue.empty? || seen.size >= limit
        node = queue.shift
        next if seen.key?(node)

        seen[node] = true
        names << node.class.name unless names.include?(node.class.name)
        queue << node.wrapped_exception if node.respond_to?(:wrapped_exception) && node.wrapped_exception
        queue << node.cause if node.cause
      end
      names
    end

    def self.parse_filters(filters)
      {
        price: filters.find { |f| f["filterType"] == "PRICE_FILTER" },
        lot_size: filters.find { |f| f["filterType"] == "LOT_SIZE" },
        notional: filters.find { |f| %w[NOTIONAL MIN_NOTIONAL].include?(f["filterType"]) }
      }
    end
  end
end
