# frozen_string_literal: true

require "digest"
require "uri"

module Honeymaker
  module Clients
    class Kraken < Client
      URL = "https://api.kraken.com"

      RATE_LIMITS = { default: 1000, orders: 1000 }.freeze

      ASSET_MAP = {
        "ZUSD" => "USD", "ZEUR" => "EUR", "ZGBP" => "GBP",
        "ZJPY" => "JPY", "ZCHF" => "CHF", "ZCAD" => "CAD",
        "ZAUD" => "AUD", "XXBT" => "XBT", "XETH" => "ETH",
        "XXDG" => "XDG"
      }.freeze

      def query_orders_info(txid:, trades: nil, userref: nil, consolidate_taker: true)
        result = post_private("/0/private/QueryOrders", {
          nonce: nonce, trades: trades, userref: userref,
          txid: txid, consolidate_taker: consolidate_taker
        })
        return result if result.failure?

        errors = result.data["error"]
        return Result::Failure.new(*errors) if errors.is_a?(Array) && errors.any?

        orders = {}
        (result.data["result"] || {}).each do |order_id, raw|
          orders[order_id] = normalize_order(order_id, raw)
        end
        Result::Success.new(orders)
      end

      def add_order(ordertype:, type:, volume:, pair:, userref: nil, cl_ord_id: nil,
                    displayvol: nil, price: nil, price2: nil, trigger: nil, leverage: nil,
                    reduce_only: nil, stptype: nil, oflags: [], timeinforce: nil,
                    starttm: nil, expiretm: nil, close: nil, close_price: nil,
                    close_price2: nil, deadline: nil, validate: nil)
        result = post_private("/0/private/AddOrder", {
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
        return result if result.failure?

        errors = result.data["error"]
        return Result::Failure.new(*errors) if errors.is_a?(Array) && errors.any?

        txid = (result.data.dig("result", "txid") || []).first
        Result::Success.new({ order_id: txid, raw: result.data })
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

      def get_balances
        result = get_extended_balance
        return result if result.failure?

        errors = result.data["error"]
        return Result::Failure.new(*errors) if errors.is_a?(Array) && errors.any?

        balances = {}
        (result.data["result"] || {}).each do |symbol, balance|
          mapped_symbol = ASSET_MAP[symbol.split(".").first] || symbol.split(".").first
          total = BigDecimal(balance["balance"].to_s)
          locked = BigDecimal((balance["hold_trade"] || "0").to_s)
          free = total - locked
          next if free.zero? && locked.zero?
          balances[mapped_symbol] = { free: free, locked: locked }
        end

        Result::Success.new(balances)
      end

      def get_ohlc_data(pair:, interval: nil, since: nil)
        get_public("/0/public/OHLC", { pair: pair, interval: interval, since: since })
      end

      def get_trades_history(type: nil, trades: nil, start: nil, end_time: nil, ofs: nil)
        post_private("/0/private/TradesHistory", {
          nonce: nonce, type: type, trades: trades,
          start: start, end: end_time, ofs: ofs
        })
      end

      def get_ledgers(asset: nil, type: nil, start: nil, end_time: nil, ofs: nil)
        post_private("/0/private/Ledgers", {
          nonce: nonce, asset: asset, type: type,
          start: start, end: end_time, ofs: ofs
        })
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

      def normalize_order(order_id, raw)
        descr = raw["descr"] || {}
        order_type = parse_order_type(descr["ordertype"])
        side = descr["type"]&.downcase&.to_sym
        status = parse_order_status(raw["status"])

        order_flags = (raw["oflags"] || "").split(",")
        if order_flags.include?("viqc")
          amount = nil
          quote_amount = BigDecimal(raw["vol"].to_s)
        else
          amount = BigDecimal(raw["vol"].to_s)
          quote_amount = nil
        end

        amount_exec = BigDecimal(raw["vol_exec"].to_s)
        quote_amount_exec = BigDecimal(raw["cost"].to_s)

        price = BigDecimal(raw["price"].to_s)
        price = BigDecimal(descr["price"].to_s) if price.zero? && order_type == :limit
        price = nil if price.zero?

        {
          order_id: order_id,
          status: status,
          side: side,
          order_type: order_type,
          price: price,
          amount: amount,
          quote_amount: quote_amount,
          amount_exec: amount_exec,
          quote_amount_exec: quote_amount_exec,
          raw: raw
        }
      end

      def parse_order_type(type)
        case type
        when "market" then :market
        when "limit" then :limit
        else :unknown
        end
      end

      def parse_order_status(status)
        case status
        when "pending" then :unknown
        when "open" then :open
        when "closed" then :closed
        when "canceled", "expired" then :cancelled
        else :unknown
        end
      end

      def validate_trading_credentials
        result = get_extended_balance
        return Result::Failure.new("Invalid trading credentials") if result.failure?

        errors = result.data["error"]
        if errors.is_a?(Array) && errors.none?
          Result::Success.new(true)
        else
          Result::Failure.new("Invalid trading credentials")
        end
      end

      def validate_read_credentials
        validate_trading_credentials
      end

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
