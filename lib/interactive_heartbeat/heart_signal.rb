# frozen_string_literal: true

module ::InteractiveHeartbeat
  class HeartSignal
    MIN_HEART_RATE = 30
    MAX_HEART_RATE = 220
    MIN_INTERVAL_MS = 273
    MAX_INTERVAL_MS = 2000

    class << self
      def for(session:, target_participant:)
        session.refresh_presence_state!
        return inactive_payload(session) unless session.status == ::InteractiveHeartbeat::Session::STATUS_ACTIVE

        source_participant = session.other_participant(target_participant.user_id)
        return inactive_payload(session) if source_participant.blank?
        return inactive_payload(session) unless session.direction_enabled?(source_participant.user_id, target_participant.user_id)
        return inactive_payload(session) unless source_participant.heartbeat_consent?
        return inactive_payload(session) unless target_participant.toy_consent?

        live = current_live_reading(source_participant.user_id)
        if live.blank?
          session.pause!
          return unavailable_payload(session.reload, "no_fresh_heartbeat")
        end

        heart_rate = live[:heart_rate].to_i
        interval_ms = [[(60_000.0 / heart_rate).round, MIN_INTERVAL_MS].max, MAX_INTERVAL_MS].min
        expires_at_ms = current_time_ms + client_signal_ttl_ms(live)

        {
          active: true,
          status: session.status,
          mode: session.mode,
          source: {
            username: source_participant.user.username,
            heart_rate: session.settings_hash[:show_exact_bpm] ? heart_rate : nil,
          },
          pulse: {
            interval_ms: interval_ms,
            strength: target_participant.pulse_strength,
            duration_ms: [target_participant.pulse_duration_ms, interval_ms - 80].min,
          },
          measured_at_ms: live[:measured_at_ms].to_i,
          expires_at_ms: expires_at_ms,
          server_time_ms: current_time_ms,
        }
      end

      private

      def current_live_reading(user_id)
        return nil unless heartrate_runtime_ready?

        account = ::LiveMetrics::ProviderAccount
          .enabled_providers
          .active
          .find_by(user_id: user_id)
        return nil if account.blank? || !account.connected?

        state = ::LiveMetrics::CurrentStateStore.read(account)
        return nil unless ::LiveMetrics::CurrentStateStore.state_with_reading?(state)

        heart_rate = state[:heart_rate].to_i
        age_seconds = state[:age_seconds].to_i
        return nil unless heart_rate.between?(MIN_HEART_RATE, MAX_HEART_RATE)
        return nil if age_seconds > SiteSetting.interactive_heartbeat_signal_stale_seconds.to_i

        state
      rescue => e
        Rails.logger.warn(
          "[interactive_heartbeat] heart_signal_failed user_id=#{user_id} " \
          "error=#{e.class}",
        )
        nil
      end

      def client_signal_ttl_ms(live)
        stale_ms = SiteSetting.interactive_heartbeat_signal_stale_seconds.to_i * 1000
        reading_age_ms = live[:age_seconds].to_i * 1000
        freshness_remaining_ms = [stale_ms - reading_age_ms, 0].max
        transport_ttl_ms = (SiteSetting.interactive_heartbeat_signal_poll_ms.to_i * 2) + 500

        [[freshness_remaining_ms, transport_ttl_ms].min, 500].max
      end

      def heartrate_runtime_ready?
        defined?(::LiveMetrics::ProviderAccount) &&
          defined?(::LiveMetrics::CurrentStateStore) &&
          defined?(::LiveMetrics::RefreshCoordinator) &&
          ::LiveMetrics::RefreshCoordinator.async_enabled?
      end

      def inactive_payload(session)
        {
          active: false,
          status: session.reload.status,
          reason: "session_not_active",
          server_time_ms: current_time_ms,
        }
      end

      def unavailable_payload(session, reason)
        {
          active: false,
          status: session.status,
          reason: reason,
          server_time_ms: current_time_ms,
        }
      end

      def current_time_ms
        (Time.now.to_f * 1000).to_i
      end
    end
  end
end
