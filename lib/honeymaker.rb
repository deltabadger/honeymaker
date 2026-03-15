# frozen_string_literal: true

require "faraday"
require "faraday/net_http_persistent"
require "json"

require_relative "honeymaker/version"
require_relative "honeymaker/result"
require_relative "honeymaker/utils"
require_relative "honeymaker/exchange"
require_relative "honeymaker/exchanges/binance"
require_relative "honeymaker/exchanges/binance_us"
require_relative "honeymaker/exchanges/kraken"
require_relative "honeymaker/exchanges/coinbase"
require_relative "honeymaker/exchanges/mexc"
require_relative "honeymaker/exchanges/gemini"
require_relative "honeymaker/exchanges/bitvavo"
require_relative "honeymaker/exchanges/bitget"
require_relative "honeymaker/exchanges/bybit"
require_relative "honeymaker/exchanges/kucoin"
require_relative "honeymaker/exchanges/hyperliquid"
require_relative "honeymaker/exchanges/bingx"
require_relative "honeymaker/exchanges/bitrue"
require_relative "honeymaker/exchanges/bitmart"

module Honeymaker
  class Error < StandardError; end

  EXCHANGES = {
    "binance" => Exchanges::Binance,
    "binance_us" => Exchanges::BinanceUs,
    "kraken" => Exchanges::Kraken,
    "coinbase" => Exchanges::Coinbase,
    "mexc" => Exchanges::Mexc,
    "gemini" => Exchanges::Gemini,
    "bitvavo" => Exchanges::Bitvavo,
    "bitget" => Exchanges::Bitget,
    "bybit" => Exchanges::Bybit,
    "kucoin" => Exchanges::Kucoin,
    "hyperliquid" => Exchanges::Hyperliquid,
    "bingx" => Exchanges::BingX,
    "bitrue" => Exchanges::Bitrue,
    "bitmart" => Exchanges::BitMart
  }.freeze

  def self.exchange(name)
    klass = EXCHANGES[name.to_s]
    raise Error, "Unknown exchange: #{name}" unless klass
    klass.new
  end
end
