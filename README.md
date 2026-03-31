# Honeymaker

[![Gem Version](https://img.shields.io/gem/v/honeymaker)](https://rubygems.org/gems/honeymaker)
[![CI](https://github.com/deltabadger/honeymaker/actions/workflows/test.yml/badge.svg)](https://github.com/deltabadger/honeymaker/actions)
[![License](https://img.shields.io/github/license/deltabadger/honeymaker)](LICENSE)

Ruby clients for cryptocurrency exchange APIs used by [Deltabadger](https://github.com/deltabadger/deltabadger).

## Supported Exchanges

Binance, Binance US, Kraken, Kraken Futures, Coinbase, Bybit, KuCoin, Bitget, MEXC, Bitvavo, Gemini, Hyperliquid, BingX, Bitrue, BitMart.

## Installation

```ruby
gem "honeymaker"
```

## Usage

### Market Data

```ruby
require "honeymaker"

exchange = Honeymaker.exchange("binance")
result = exchange.get_tickers_info

if result.success?
  result.data.each do |ticker|
    puts "#{ticker[:ticker]} — min: #{ticker[:minimum_quote_size]}, decimals: #{ticker[:base_decimals]}"
  end
end
```

### Balances

```ruby
client = Honeymaker.client("binance", api_key: "...", api_secret: "...")
result = client.get_balances

if result.success?
  result.data.each do |symbol, balance|
    puts "#{symbol}: free=#{balance[:free]}, locked=#{balance[:locked]}"
  end
end
# => { "BTC" => { free: BigDecimal("0.5"), locked: BigDecimal("0.1") }, ... }
```

Coinbase auto-resolves the default portfolio, or pass one explicitly:

```ruby
client.get_balances(portfolio_uuid: "...")
```

### Placing Orders

Order placement returns a normalized `{ order_id:, raw: }` hash:

```ruby
client = Honeymaker.client("binance", api_key: "...", api_secret: "...")

result = client.new_order(symbol: "BTCUSDT", side: "BUY", type: "MARKET", quote_order_qty: "100")
if result.success?
  puts result.data[:order_id]  # => "BTCUSDT-123456"
  puts result.data[:raw]       # full exchange response
end
```

Method names vary by exchange (`new_order`, `create_order`, `add_order`, `place_order`, `submit_order`) but the return format is the same.

### Querying Orders

Order queries return a normalized hash with unified status, amounts, and the raw response:

```ruby
result = client.query_order(symbol: "BTCUSDT", order_id: 123456)
if result.success?
  order = result.data
  order[:order_id]          # => "BTCUSDT-123456"
  order[:status]            # => :open, :closed, :cancelled, :failed, :unknown
  order[:side]              # => :buy, :sell
  order[:order_type]        # => :market, :limit
  order[:price]             # => BigDecimal — avg fill price
  order[:amount]            # => BigDecimal — requested base qty (nil if quote-denominated)
  order[:quote_amount]      # => BigDecimal — requested quote qty (nil if base-denominated)
  order[:amount_exec]       # => BigDecimal — filled base qty
  order[:quote_amount_exec] # => BigDecimal — filled quote qty
  order[:raw]               # => Hash — full exchange response
end
```

### Account History (Tax Reporting)

History endpoints for margin, futures, staking/earn, and other tax-relevant events:

```ruby
# Margin
client.margin_borrow_repay_history(type: "BORROW")   # Binance
client.margin_interest_history                         # Binance, KuCoin, Bitget
client.margin_force_liquidation                        # Binance

# Futures
client.futures_income_history(income_type: "REALIZED_PNL")  # Binance USDT-M
client.coin_futures_income_history                          # Binance Coin-M
client.futures_account_bills(product_type: "USDT-FUTURES")  # Bitget
client.futures_income                                       # BingX

# Staking / Earn
client.simple_earn_flexible_rewards                    # Binance
client.simple_earn_locked_subscriptions                # Binance
client.earn_yield_history                              # Bybit
client.staking_rewards                                 # Gemini
client.staking_rewards_history                         # Binance US

# Other
client.universal_transfer_history(type: "MAIN_MARGIN") # Binance
client.dust_log                                        # Binance
client.asset_dividend                                  # Binance
```

Coverage varies by exchange. Kraken's `get_ledgers(type:)` covers margin, staking, and trades in a single endpoint. Coinbase's `list_transactions` covers 30+ event types.

### Kraken Futures

Kraken Futures uses separate API keys and a different auth scheme — it's a standalone client:

```ruby
client = Honeymaker.client("kraken_futures", api_key: "...", api_secret: "...")

client.get_accounts                                  # wallet balances, margin, PnL
client.get_fills                                     # trade fills
client.get_open_positions                            # open positions
client.historical_funding_rates(symbol: "PF_XBTUSD") # funding rate history
```

### Credential Validation

```ruby
client = Honeymaker.client("binance", api_key: "...", api_secret: "...")
result = client.validate(:trading)
result.success? # => true if credentials have trading permissions
```

### Rate Limits

Each exchange exposes rate limit metadata (milliseconds between requests):

```ruby
Honeymaker::Clients::Binance.rate_limits
# => { default: 100, orders: 200 }

Honeymaker::Clients::Kraken.rate_limits
# => { default: 1000, orders: 1000 }
```

### Proxy Support

```ruby
client = Honeymaker.client("binance",
  api_key: "...", api_secret: "...",
  proxy: "http://proxy:8100"
)
```

## Result Objects

All methods return `Result::Success` or `Result::Failure`:

```ruby
result = client.get_balances
result.success?  # true/false
result.failure?  # true/false
result.data      # response payload
result.errors    # array of error messages (empty on success)
```

## License

MIT
