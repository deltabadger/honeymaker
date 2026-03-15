# frozen_string_literal: true

module Honeymaker
  module Utils
    def self.decimals(num)
      str = num.to_s.sub(/\.?0+$/, "")
      return 0 unless str.include?(".")
      str.split(".").last.length
    end
  end
end
