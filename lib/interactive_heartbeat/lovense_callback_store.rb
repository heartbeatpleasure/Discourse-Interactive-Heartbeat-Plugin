# frozen_string_literal: true

require "json"

module ::InteractiveHeartbeat
  class LovenseCallbackStore
    VERSION = 1
    KEY_PREFIX = "interactive_heartbeat:lovense_callback:v1"
    DEFAULT_TTL_SECONDS = 60
    MIN_TTL_SECONDS = 20
    MAX_TTL_SECONDS = 300

    class << self
      def write(user:, payload:)
        return nil if user.blank? || user.id.blank?

        state = normalized_state(payload)
        serialized = JSON.generate(state)
        written = redis.set(key(user.id), serialized, ex: ttl_seconds)
        written.present? ? state.deep_symbolize_keys : nil
      rescue => e
        Rails.logger.warn(
          "[interactive_heartbeat] lovense_callback_store_write_failed " \
          "user_id=#{user&.id} error=#{e.class}",
        )
        nil
      end

      def read(user_or_id)
        user_id = user_id_for(user_or_id)
        return nil if user_id.blank?

        raw = redis.get(key(user_id))
        return nil if raw.blank?

        parsed = JSON.parse(raw)
        return nil unless parsed["v"].to_i == VERSION

        parsed.deep_symbolize_keys
      rescue JSON::ParserError, TypeError, ArgumentError
        nil
      rescue => e
        Rails.logger.warn(
          "[interactive_heartbeat] lovense_callback_store_read_failed " \
          "user_id=#{user_id} error=#{e.class}",
        )
        nil
      end

      def delete(user_or_id)
        user_id = user_id_for(user_or_id)
        return false if user_id.blank?

        redis.del(key(user_id))
        true
      rescue => e
        Rails.logger.warn(
          "[interactive_heartbeat] lovense_callback_store_delete_failed " \
          "user_id=#{user_id} error=#{e.class}",
        )
        false
      end

      def key(user_or_id)
        user_id = user_id_for(user_or_id)
        "#{KEY_PREFIX}:#{user_id}"
      end

      def ttl_seconds
        value = SiteSetting.interactive_heartbeat_lovense_callback_ttl_seconds.to_i
        value = DEFAULT_TTL_SECONDS unless value.positive?
        [[value, MIN_TTL_SECONDS].max, MAX_TTL_SECONDS].min
      end

      private

      def redis
        Discourse.redis
      end

      def normalized_state(payload)
        input = payload.respond_to?(:to_unsafe_h) ? payload.to_unsafe_h : payload.to_h
        toys = normalized_toys(input["toys"] || input[:toys])
        online_toys = toys.values.count { |toy| toy_online?(toy) }

        {
          "v" => VERSION,
          "received_at_ms" => (Time.zone.now.to_f * 1000).to_i,
          "app_type" => normalized_text(input["appType"] || input[:appType], 32),
          "platform" => normalized_text(input["platform"] || input[:platform], 32),
          "app_version" => normalized_text(input["appVersion"] || input[:appVersion], 32),
          "protocol_version" => normalized_text(input["version"] || input[:version], 16),
          "toy_count" => toys.length,
          "online_toy_count" => online_toys,
        }
      end

      def normalized_toys(value)
        parsed =
          if value.is_a?(String)
            JSON.parse(value)
          elsif value.respond_to?(:to_unsafe_h)
            value.to_unsafe_h
          elsif value.respond_to?(:to_h)
            value.to_h
          else
            {}
          end

        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError, TypeError
        {}
      end

      def toy_online?(toy)
        value =
          if toy.respond_to?(:to_unsafe_h)
            toy.to_unsafe_h["status"]
          elsif toy.respond_to?(:to_h)
            toy.to_h["status"] || toy.to_h[:status]
          end

        ActiveModel::Type::Boolean.new.cast(value) || value.to_i == 1
      rescue
        false
      end

      def normalized_text(value, max_length)
        value.to_s.strip.first(max_length)
      end

      def user_id_for(user_or_id)
        value = user_or_id.respond_to?(:id) ? user_or_id.id : user_or_id
        id = Integer(value, exception: false)
        id&.positive? ? id : nil
      end
    end
  end
end
