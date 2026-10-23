# frozen_string_literal: true

require "bigdecimal"

module Honeymaker
  # Minimum order values venues enforce but do not publish (or publish too low), found by test
  # orders. A ticker's minimum_quote_size is max(published, floor): a floor never lowers a minimum
  # the venue itself raised. Consumed by the venue parsers here and by data-api for venues it
  # builds itself (Alpaca crypto).
  module Floors
    ANY_QUOTE = :any

    # [venue, asset_class] => { quote => floor }. A nil asset class covers every class the venue
    # lists; ANY_QUOTE covers every quote.
    MINIMUM_QUOTE = {
      # Kraken's AssetPairs costmin is below what AddOrder accepts ("EOrder:Cost minimum not met");
      # these are the per-quote costs it actually enforces. The native core mirrors this table
      # (crates/honeymaker/src/kraken/normalize.rs REAL_COSTMIN; parity-tested).
      ["kraken", nil] => {
        "AUD" => 10,
        "CAD" => 5,
        "CHF" => 5,
        "DAI" => 5,
        "ETH" => 0.002,
        "EUR" => 0.5,
        "GBP" => 5,
        "JPY" => 500,
        "PYUSD" => 5,
        "RLUSD" => 5,
        "USD" => 5,
        "USDC" => 5,
        "USDQ" => 5,
        "USDR" => 5,
        "USDT" => 5,
        "XBT" => 0.00005
      },
      # "Order must have minimum value of 10 USDC." on every spot pair; spotMeta publishes no
      # minimum. The value is measured in USDC whatever the pair's quote, so it covers all quotes.
      ["hyperliquid", nil] => { ANY_QUOTE => 10 },
      # "cost basis must be >= minimal amount of order 10" on crypto; the assets API publishes only
      # min_order_size (base). Stocks are not floored here (notional orders from $1).
      ["alpaca", "crypto"] => { "USD" => 10 }
    }.freeze

    # The minimum quote size to store: max(published, floor). Returns published when no floor
    # applies (nil when neither exists), and the floor when published is missing or not a number.
    # Whichever wins is returned as given, so callers keep their own formatting.
    def self.minimum_quote(venue:, quote:, asset_class: nil, published: nil)
      quotes = MINIMUM_QUOTE[[venue.to_s, asset_class&.to_s]] || MINIMUM_QUOTE[[venue.to_s, nil]] || {}
      floor = quotes.fetch(quote.to_s) { quotes[ANY_QUOTE] }
      return published if floor.nil?
      return floor if published.nil?

      BigDecimal(published.to_s) > BigDecimal(floor.to_s) ? published : floor
    rescue ArgumentError
      floor
    end
  end
end
