# frozen_string_literal: true

require "uri"

module Honeymaker
  module Native
    # Kraken on the Rust core. Signatures and argument expressions are copied from Clients::Kraken
    # (a test compares signatures). Transport, body encoding and Results are the inherited,
    # unchanged Ruby: connection + URI.encode_www_form + with_rescue. Rust lays out and signs the
    # requests and normalizes the answers.
    class KrakenClient < Honeymaker::Client
      URL = "https://api.kraken.com"
      RATE_LIMITS = { default: 1000, orders: 1000 }.freeze
      UNREADABLE = "Kraken: unreadable response"

      def self.reset_nonce_state!
        Native.load!
        Ext::Kraken.reset_nonce_state!
      end

      def query_orders_info(txid:, trades: nil, userref: nil, consolidate_taker: true)
        result = post_private("query_orders_info", trades: trades, userref: userref, txid: txid, consolidate_taker: consolidate_taker)
        finish("query_orders_info", result) do |orders|
          (result.data["result"] || {}).each { |id, raw| orders[id][:raw] = raw }
          orders
        end
      end

      def add_order(ordertype:, type:, volume:, pair:, userref: nil, cl_ord_id: nil,
                    displayvol: nil, price: nil, price2: nil, trigger: nil, leverage: nil,
                    reduce_only: nil, stptype: nil, oflags: [], timeinforce: nil,
                    starttm: nil, expiretm: nil, close: nil, close_price: nil,
                    close_price2: nil, deadline: nil, validate: nil)
        result = post_private("add_order",
                              ordertype: ordertype, type: type, volume: volume, pair: pair, userref: userref,
                              cl_ord_id: cl_ord_id, displayvol: displayvol, price: price, price2: price2,
                              trigger: trigger, leverage: leverage, reduce_only: reduce_only, stptype: stptype,
                              oflags: oflags.any? ? oflags.join(",") : nil,
                              timeinforce: timeinforce, starttm: starttm, expiretm: expiretm, close: close,
                              close_price: close_price, close_price2: close_price2, deadline: deadline, validate: validate)
        finish("add_order", result) { |order_id| { order_id: order_id, raw: result.data } }
      end

      def cancel_order(txid: nil, cl_ord_id: nil)
        post_private("cancel_order", txid: txid, cl_ord_id: cl_ord_id)
      end

      def get_tradable_asset_pairs(pairs: nil, info: nil, country_code: nil, aclass_base: nil)
        get_public("get_tradable_asset_pairs", pairs: pairs ? pairs.join(",") : nil, info: info,
                                               country_code: country_code, aclass_base: aclass_base)
      end

      def get_asset_info(assets: nil, aclass: nil)
        get_public("get_asset_info", assets: assets ? assets.join(",") : nil, aclass: aclass)
      end

      def get_ticker_information(pair: nil)
        get_public("get_ticker_information", pair: pair)
      end

      def get_extended_balance
        post_private("get_extended_balance")
      end

      def get_api_key_info
        post_private("get_api_key_info")
      end

      def get_balances
        finish("balances", get_extended_balance) { |balances| balances }
      end

      def get_ohlc_data(pair:, interval: nil, since: nil)
        get_public("get_ohlc_data", pair: pair, interval: interval, since: since)
      end

      def get_trades_history(type: nil, trades: nil, start: nil, end_time: nil, ofs: nil)
        post_private("get_trades_history", type: type, trades: trades, start: start, end_time: end_time, ofs: ofs)
      end

      def get_ledgers(asset: nil, type: nil, start: nil, end_time: nil, ofs: nil)
        post_private("get_ledgers", asset: asset, type: type, start: start, end_time: end_time, ofs: ofs)
      end

      # The paging loop stays Ruby (verbatim legacy) so dig/to_i/include? keep Ruby's
      # coercions; Rust aggregates. A Rust pager comes with stage 2, when Rust callers need one.
      def closed_orders_from_trades(order_ids:, start: nil, max_pages: 20)
        wanted = Array(order_ids)
        return Result::Success.new({}) if wanted.empty?

        by_order = Hash.new { |h, k| h[k] = [] }
        offset = 0
        pages = 0
        loop do
          result = get_trades_history(start: start, ofs: offset)
          return result if result.failure?
          return unreadable unless result.data.is_a?(Hash)

          errors = result.data["error"]
          return Result::Failure.new(*errors) if errors.is_a?(Array) && errors.any?

          trades = result.data.dig("result", "trades") || {}
          break if trades.empty?

          trades.each_value do |t|
            otxid = t["ordertxid"]
            by_order[otxid] << t if wanted.include?(otxid)
          end

          # Do NOT early-exit when each id has been *seen* — a partial fill can have trades on
          # later pages. Page the whole [start, now] window (bounded by `start` + max_pages).
          pages += 1
          offset += trades.size
          count = result.data.dig("result", "count").to_i
          break if offset >= count || pages >= max_pages
        end

        Native.load!
        Result::Success.new(Ext::Kraken.aggregate_trades(by_order))
      end

      def get_withdraw_addresses(asset: nil, method: nil)
        post_private("get_withdraw_addresses", asset: asset, method: method)
      end

      def get_withdraw_methods(asset: nil)
        post_private("get_withdraw_methods", asset: asset)
      end

      def withdraw(asset:, key:, amount:, address: nil)
        post_private("withdraw", asset: asset, key: key, amount: amount, address: address)
      end

      def get_earn_allocations(ascending: nil, converted_asset: nil, hide_zero_allocations: nil)
        post_private("get_earn_allocations", ascending: ascending, converted_asset: converted_asset,
                                             hide_zero_allocations: hide_zero_allocations)
      end

      private

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

      def native
        @native ||= begin
          Native.load!
          Ext::Kraken.new(@api_key, @api_secret)
        end
      end

      # The legacy post_private: Rust lays out the pairs (nonce first) and signs; Ruby encodes.
      def post_private(op, params = {})
        with_rescue do
          path, pairs = native.build_post(op, params.transform_keys(&:to_s))
          response = connection.post do |req|
            req.url path
            req.body = URI.encode_www_form(pairs)
            req.headers = native.sign(req.path, req.body)
          end
          response.body
        end
      end

      # The legacy get_public: Rust lays out the params; Faraday encodes them.
      def get_public(op, params = {})
        with_rescue do
          path, query, headers = native.build_get(op, params.transform_keys(&:to_s))
          response = connection.get do |req|
            req.url path
            req.headers = headers
            req.params = query
          end
          response.body
        end
      end

      def finish(op, result)
        return result if result.failure?
        # Guard in Ruby, before any conversion: a binary maintenance page must answer like the
        # hardened legacy, not fail inside the converter.
        return unreadable unless result.data.is_a?(Hash)

        verdict = native.finish(op, result.data)
        case verdict[0]
        when "ok" then Result::Success.new(yield(verdict[1]))
        when "venue" then Result::Failure.new(*result.data["error"])
        when "unreadable" then unreadable
        end
      end

      def unreadable
        Result::Failure.new(UNREADABLE, data: { unreadable: true })
      end
    end

    class KrakenExchange < Honeymaker::Exchange
      BASE_URL = "https://api.kraken.com"

      def classify_error(message)
        return nil if message.nil?

        Native.load!
        Ext::Kraken.classify_error(message)
      end

      def get_tickers_info
        with_rescue do
          response = connection.get("/0/public/AssetPairs", { aclass_base: "all" })
          raise ShapeError, "Kraken: catalogue body is not an object" unless response.body.is_a?(Hash)

          verdict = native.finish("tickers_info", response.body)
          return Result::Failure.new(*response.body["error"]) if verdict[0] == "venue"

          verdict[1].each { |t| t[:minimum_quote_size] = t[:minimum_quote_size].to_s }
        end
      end

      def get_bid_ask(symbol)
        with_rescue do
          response = connection.get("/0/public/Ticker") { |req| req.params = { pair: symbol } }
          raise ShapeError, "Kraken: ticker body is not an object" unless response.body.is_a?(Hash)

          verdict = native.finish("bid_ask", response.body)
          raise StandardError, response.body["error"].first if verdict[0] == "venue"

          verdict[1]
        end
      end

      private

      def native
        @native ||= begin
          Native.load!
          Ext::Kraken.new(nil, nil)
        end
      end

      def connection
        @connection ||= build_connection(BASE_URL)
      end
    end
  end
end
