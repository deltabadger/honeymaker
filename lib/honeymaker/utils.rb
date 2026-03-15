# frozen_string_literal: true

module Honeymaker
  module Utils
    def self.decimals(num)
      return 0 if num.nil?
      str = num.to_s.sub(/\.?0+$/, "")
      return 0 unless str.include?(".")
      str.split(".").last.length
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
