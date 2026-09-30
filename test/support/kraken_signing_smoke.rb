# frozen_string_literal: true

require "json"

module KrakenSigningSmoke
  VECTORS = File.expand_path("../../crates/honeymaker/tests/vectors/kraken_signing.json", __dir__)

  def self.verify!
    vector = JSON.parse(File.read(VECTORS)).find do |entry|
      !entry.fetch("api_key").empty? && !entry.fetch("api_secret").empty?
    end
    abort "no authenticated Kraken signing vector" unless vector

    signer = Honeymaker::Native::Ext::Kraken.new(vector.fetch("api_key"), vector.fetch("api_secret"))
    headers = signer.sign(vector.fetch("path"), vector.fetch("body"))
    %w[API-Key API-Sign].each do |field|
      abort "Kraken signing vector mismatch: #{field}" unless headers[field] == vector.fetch("headers").fetch(field)
    end
    true
  end
end
