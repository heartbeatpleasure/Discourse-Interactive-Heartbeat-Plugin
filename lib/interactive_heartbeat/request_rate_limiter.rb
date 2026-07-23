# frozen_string_literal: true

module ::InteractiveHeartbeat
  class RequestRateLimiter
    LIMITS = {
      "users" => [30, 60],
      "invitation_preferences" => [60, 60],
      "update_invitation_preferences" => [20, 300],
      "add_invitation_member" => [30, 300],
      "remove_invitation_member" => [30, 300],
      "sessions" => [60, 60],
      "clear_completed_sessions" => [10, 300],
      "create_session" => [10, 300],
      "show_session" => [120, 60],
      "accept_session" => [30, 60],
      "join_session" => [30, 60],
      "grant_permissions" => [60, 60],
      "revoke_permissions" => [30, 60],
      "decline_session" => [30, 60],
      "update_participant" => [60, 60],
      "update_configuration" => [30, 60],
      "start_session" => [30, 60],
      "pause_session" => [30, 60],
      "end_session" => [30, 60],
      "presence" => [120, 60],
      "signal" => [180, 60],
      "lovense_token" => [10, 300],
      "test_lab_signal" => [180, 60],
      "test_lab_lovense_token" => [10, 300],
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

      def perform_invite_creation!(user)
        max = SiteSetting.interactive_heartbeat_invites_per_day.to_i
        return if max <= 0

        day = Time.zone.today.iso8601
        key = "interactive_heartbeat:invite_daily:v1:#{user.id}:#{day}"
        count = Discourse.redis.incr(key)
        Discourse.redis.expire(key, 2.days.to_i) if count == 1
        raise LimitExceeded if count > max
      rescue Redis::BaseError => e
        Rails.logger.warn(
          "[interactive_heartbeat] invite_daily_limit_redis_failed " \
          "user_id=#{user&.id} error=#{e.class}",
        )
      end
    end
  end
end
