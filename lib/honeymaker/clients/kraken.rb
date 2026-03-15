# frozen_string_literal: true

require "digest"
require "uri"

module Honeymaker
  module Clients
    class Kraken < Client
      URL = "https://api.kraken.com"

      def query_orders_info(txid:, trades: nil, userref: nil, consolidate_taker: true)
        post_private("/0/private/QueryOrders", {
          nonce: nonce, trades: trades, userref: userref,
          txid: txid, consolidate_taker: consolidate_taker
        })
      end

      def add_order(ordertype:, type:, volume:, pair:, userref: nil, cl_ord_id: nil,
                    displayvol: nil, price: nil, price2: nil, trigger: nil, leverage: nil,
                    reduce_only: nil, stptype: nil, oflags: [], timeinforce: nil,
                    starttm: nil, expiretm: nil, close: nil, close_price: nil,
                    close_price2: nil, deadline: nil, validate: nil)
        post_private("/0/private/AddOrder", {
          "nonce" => nonce, "ordertype" => ordertype, "type" => type,
          "volume" => volume, "pair" => pair, "userref" => userref,
          "cl_ord_id" => cl_ord_id, "displayvol" => displayvol,
          "price" => price, "price2" => price2, "trigger" => trigger,
          "leverage" => leverage, "reduce_only" => reduce_only,
          "stptype" => stptype,
          "oflags" => oflags.any? ? oflags.join(",") : nil,
          "timeinforce" => timeinforce, "starttm" => starttm,
          "expiretm" => expiretm, "close[ordertype]" => close,
          "close[price]" => close_price, "close[price2]" => close_price2,
          "deadline" => deadline, "validate" => validate
        })
      end

      def cancel_order(txid: nil, cl_ord_id: nil)
        post_private("/0/private/CancelOrder", { nonce: nonce, txid: txid, cl_ord_id: cl_ord_id })
      end

      def get_tradable_asset_pairs(pairs: nil, info: nil, country_code: nil)
        get_public("/0/public/AssetPairs", {
          pair: pairs ? pairs.join(",") : nil, info: info, country_code: country_code
        })
      end

      def get_asset_info(assets: nil, aclass: nil)
        get_public("/0/public/Assets", { asset: assets ? assets.join(",") : nil, aclass: aclass })
      end

      def get_ticker_information(pair: nil)
        get_public("/0/public/Ticker", { pair: pair })
      end

      def get_extended_balance
        post_private("/0/private/BalanceEx", { nonce: nonce })
      end

      def get_ohlc_data(pair:, interval: nil, since: nil)
        get_public("/0/public/OHLC", { pair: pair, interval: interval, since: since })
      end

      def get_withdraw_addresses(asset: nil, method: nil)
        post_private("/0/private/WithdrawAddresses", { nonce: nonce, asset: asset, method: method })
      end

      def get_withdraw_methods(asset: nil)
        post_private("/0/private/WithdrawMethods", { nonce: nonce, asset: asset })
      end

      def withdraw(asset:, key:, amount:, address: nil)
        post_private("/0/private/Withdraw", { nonce: nonce, asset: asset, key: key, amount: amount, address: address })
      end

      private

      def get_public(path, params = {})
        with_rescue do
          response = connection.get do |req|
            req.url path
            req.headers = public_headers
            req.params = params.compact
          end
          response.body
        end
      end

      def post_private(path, body = {})
        with_rescue do
          response = connection.post do |req|
            req.url path
            req.body = URI.encode_www_form(body.compact)
            req.headers = private_headers(req.path, req.body)
          end
          response.body
        end
      end

      def nonce
        (Time.now.utc.to_f * 1_000_000).to_i
      end

      def private_headers(path, body)
        return public_headers unless authenticated?

        request_nonce = URI.decode_www_form(body).to_h["nonce"]
        data = "#{request_nonce}#{body}"
        message = path + Digest::SHA256.digest(data)
        decoded_key = Base64.decode64(@api_secret)
        begin
          hmac = OpenSSL::HMAC.digest("sha512", decoded_key, message)
        rescue OpenSSL::HMACError
          return public_headers
        end
        signature = Base64.strict_encode64(hmac)

        {
          "API-Key": @api_key,
          "API-Sign": signature,
          Accept: "application/json",
          "Content-Type": "application/x-www-form-urlencoded",
          "User-Agent": "Honeymaker Ruby"
        }
      end

      def public_headers
        { Accept: "application/json", "Content-Type": "application/json", "User-Agent": "Honeymaker Ruby" }
      end
    end
  end
end
