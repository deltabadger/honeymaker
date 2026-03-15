# Honeymaker

[![Gem Version](https://img.shields.io/gem/v/honeymaker)](https://rubygems.org/gems/honeymaker)
[![CI](https://github.com/deltabadger/honeymaker/actions/workflows/test.yml/badge.svg)](https://github.com/deltabadger/honeymaker/actions)
[![License](https://img.shields.io/github/license/deltabadger/honeymaker)](LICENSE)

Ruby clients for cryptocurrency exchange APIs. Originally extracted from [Deltabadger](https://github.com/deltabadger/deltabadger).

## Supported Exchanges

Binance, Binance US, Kraken, Coinbase, Bybit, KuCoin, Bitget, MEXC, Bitvavo, Gemini, Hyperliquid, BingX, Bitrue, BitMart.

## Installation

```ruby
gem "honeymaker"
```

## Usage

```ruby
require "honeymaker"

# Get an exchange client
exchange = Honeymaker.exchange("binance")

# Fetch trading pair info (symbols, decimals, min/max amounts)
result = exchange.get_tickers_info

if result.success?
  result.data.each do |ticker|
    puts "#{ticker[:ticker]} — min: #{ticker[:minimum_quote_size]}, decimals: #{ticker[:base_decimals]}"
  end
else
  puts "Error: #{result.errors.join(', ')}"
end
```

## License

MIT
