# frozen_string_literal: true

# Regenerates crates/honeymaker/tests/vectors/*.json from the LEGACY Ruby implementation.
#   bundle exec ruby -Ilib script/vectors/kraken.rb
require "honeymaker"
require "json"
require "bigdecimal"

out_dir = File.expand_path("../../crates/honeymaker/tests/vectors", __dir__)

secrets = [
  Base64.strict_encode64("test_secret_key_1234567890123456"),
  "dGVzd A==\n!!-_x", "abc", "=abc", "", "   ", "a", "ab==cd", "not base64 at all ~~~",
  Base64.strict_encode64((0..255).to_a.pack("C*"))
]
bodies = [
  [["nonce", "1727000000000001"]],
  [["nonce", "1727000000000002"], ["ordertype", "market"], ["type", "buy"], ["volume", "0.001"], ["pair", "XBTUSDT"],
   ["oflags", "viqc"], ["close[ordertype]", "limit"]],
  [["nonce", "1727000000000003"], ["txid", "O1,O2"], ["consolidate_taker", "true"]],
  [["nonce", "1727000000000004"], ["asset", "a b~*-._/,:[]\u00e9+&="]]
]
paths = %w[/0/private/BalanceEx /0/private/AddOrder /0/private/QueryOrders /0/private/Earn/Allocations]

signing = []
secrets.each do |secret|
  [["key", secret], ["", secret], ["key", ""]].each do |key, sec|
    bodies.each_with_index do |pairs, i|
      body = URI.encode_www_form(pairs)
      c = Honeymaker::Clients::Kraken.new(api_key: key, api_secret: sec)
      signing << { api_key: key, api_secret: sec, path: paths[i], pairs: pairs, body: body,
                   decoded_secret_hex: Base64.decode64(sec).unpack1("H*"),
                   headers: c.send(:private_headers, paths[i], body).transform_keys(&:to_s) }
    end
  end
end

decimal_inputs = ["0.5", "1", "-0", "-0.0000", "0.0000000001", "123456789012345678901234567890.123456789",
                  "1e-9", "1E5", " 1.5 ", "1_000.5", ".5", "5.", "+2", "", "abc", "1,5", "0x10", "NaN",
                  "Infinity", "-Infinity", "1d2", "true"]
decimals = decimal_inputs.map do |s|
  v = BigDecimal(s)
  { input: s, ok: true, finite: v.finite?, plain: v.finite? ? v.to_s("F") : v.to_s, sign: v.sign }
rescue ArgumentError => e
  { input: s, ok: false, error: e.message }
end

File.write(File.join(out_dir, "kraken_signing.json"), JSON.pretty_generate(signing))
File.write(File.join(out_dir, "decimal.json"), JSON.pretty_generate(decimals))
puts "wrote #{signing.size} signing vectors, #{decimals.size} decimals"
