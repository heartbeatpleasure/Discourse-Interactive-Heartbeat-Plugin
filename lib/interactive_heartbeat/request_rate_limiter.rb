# frozen_string_literal: true

module ::InteractiveHeartbeat
  class RequestRateLimiter
    LIMITS = {
      "users" => [30, 60],
      "sessions" => [60, 60],
      "create_session" => [10, 300],
      "show_session" => [120, 60],
      "accept_session" => [30, 60],
      "decline_session" => [30, 60],
      "update_participant" => [60, 60],
      "update_configuration" => [30, 60],
      "start_session" => [30, 60],
      "pause_session" => [30, 60],
      "end_session" => [30, 60],
      "presence" => [120, 60],
      "signal" => [180, 60],
      "lovense_token" => [10, 300],
    }.freeze

    class LimitExceeded < StandardError
    end

    class << self
      def perform!(action, user)
        max, period = LIMITS.fetch(action.to_s, [60, 60])
        bucket = Time.now.to_i / period
        key = "interactive_heartbeat:rate:v1:#{action}:#{user.id}:#{bucket}"
        count = Discourse.redis.incr(key)
        Discourse.redis.expire(key, period + 5) if count == 1
        raise LimitExceeded if count > max
      rescue Redis::BaseError => e
        Rails.logger.warn(
          "[interactive_heartbeat] rate_limit_redis_failed " \
          "action=#{action} error=#{e.class}",
        )
      end
    end
  end
end
