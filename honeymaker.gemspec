# frozen_string_literal: true

require_relative "lib/honeymaker/version"

Gem::Specification.new do |spec|
  spec.name = "honeymaker"
  spec.version = Honeymaker::VERSION
  spec.authors = ["Deltabadger"]
  spec.email = ["hello@deltabadger.com"]

  spec.summary = "Ruby clients for cryptocurrency exchange APIs"
  spec.description = "Unified interface for fetching market data from cryptocurrency exchanges. " \
                     "Supports Binance, Kraken, Coinbase, Bybit, KuCoin, Bitget, MEXC, and more."
  spec.homepage = "https://github.com/deltabadger/honeymaker"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "faraday", "~> 2.0"
  spec.add_dependency "faraday-net_http_persistent", "~> 2.0"
  spec.add_dependency "net-http-persistent", "~> 4.0"
end
