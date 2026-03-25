# frozen_string_literal: true

module Honeymaker
  module Clients
    class BinanceUs < Binance
      URL = "https://api.binance.us"

      # --- Staking ---

      def staking_history(staking_type: nil, asset: nil, start_time: nil, end_time: nil, page: nil, limit: nil)
        with_rescue do
          response = connection.get do |req|
            req.url "/staking/v1/history"
            req.headers = headers
            req.params = {
              stakingType: staking_type, asset: asset,
              startTime: start_time, endTime: end_time,
              page: page, limit: limit, timestamp: timestamp_ms
            }.compact
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end

      def staking_rewards_history(asset: nil, start_time: nil, end_time: nil, page: nil, limit: nil)
        with_rescue do
          response = connection.get do |req|
            req.url "/staking/v1/rewardsHistory"
            req.headers = headers
            req.params = {
              asset: asset, startTime: start_time, endTime: end_time,
              page: page, limit: limit, timestamp: timestamp_ms
            }.compact
            req.params[:signature] = sign_params(req.params)
          end
          response.body
        end
      end
    end
  end
end
