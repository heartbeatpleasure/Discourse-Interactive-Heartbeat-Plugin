# frozen_string_literal: true

module ::InteractiveHeartbeat
  class HeartSignal
    MIN_HEART_RATE = 30
    MAX_HEART_RATE = 220
    MIN_INTERVAL_MS = 273
    MAX_INTERVAL_MS = 2000
    MIN_COMMAND_GAP_MS = 140

    class << self
      def for(session:, target_participant:)
        session.refresh_presence_state!
        return inactive_payload(session, "session_not_active") unless session.status == ::InteractiveHeartbeat::Session::STATUS_ACTIVE

        source_participant = session.other_participant(target_participant.user_id)
        return inactive_payload(session, "source_missing") if source_participant.blank?
        unless session.direction_enabled?(source_participant.user_id, target_participant.user_id)
          return inactive_payload(session, "direction_disabled")
        end
        return inactive_payload(session, "consent_missing") unless source_participant.heartbeat_consent?
        return inactive_payload(session, "consent_missing") unless target_participant.toy_consent?

        now_ms = current_time_ms
        live, failure_reason = current_live_reading(source_participant.user_id)
        if live.blank?
          if %w[read_error signal_temporarily_unavailable].include?(failure_reason)
            return unavailable_payload(session, "signal_temporarily_unavailable")
          end

          session.pause!
          return unavailable_payload(session.reload, failure_reason || "no_fresh_heartbeat")
        end

        heart_rate = live[:heart_rate].to_i
        measured_at_ms = live[:measured_at_ms].to_i
        source_age_ms = [now_ms - measured_at_ms, 0].max
        lost_after_ms = signal_lost_seconds * 1000
        unstable_after_ms = [signal_unstable_seconds * 1000, lost_after_ms - 1000].min

        if source_age_ms >= lost_after_ms
          session.pause!
          return unavailable_payload(session.reload, "no_fresh_heartbeat")
        end

        interval_ms = [[(60_000.0 / heart_rate).round, MIN_INTERVAL_MS].max, MAX_INTERVAL_MS].min
        valid_for_ms = [lost_after_ms - source_age_ms, 0].max

        {
          active: true,
          status: session.status,
          mode: session.mode,
          signal_state: source_age_ms >= unstable_after_ms ? "unstable" : "live",
          source: {
            username: source_participant.user.username,
            heart_rate: session.settings_hash[:show_exact_bpm] ? heart_rate : nil,
          },
          pulse: {
            interval_ms: interval_ms,
            strength: target_participant.pulse_strength,
            duration_ms: [
              target_participant.pulse_duration_ms,
              [interval_ms - MIN_COMMAND_GAP_MS, 100].max,
            ].min,
          },
          measured_at_ms: measured_at_ms,
          source_age_ms: source_age_ms,
          unstable_after_ms: unstable_after_ms,
          lost_after_ms: lost_after_ms,
          valid_for_ms: valid_for_ms,
          expires_at_ms: now_ms + valid_for_ms,
          server_time_ms: now_ms,
        }
      end

      private

      def current_live_reading(user_id)
        return [nil, "runtime_not_ready"] unless heartrate_runtime_ready?

        account = ::LiveMetrics::ProviderAccount
          .enabled_providers
          .active
          .find_by(user_id: user_id)
        return [nil, "source_disconnected"] if account.blank? || !account.connected?

        state = ::LiveMetrics::CurrentStateStore.read(account)
        unless ::LiveMetrics::CurrentStateStore.state_with_reading?(state)
          return [nil, "signal_temporarily_unavailable"]
        end

        heart_rate = state[:heart_rate].to_i
        return [nil, "invalid_heartbeat"] unless heart_rate.between?(MIN_HEART_RATE, MAX_HEART_RATE)

        [state, nil]
      rescue => e
        Rails.logger.warn(
          "[interactive_heartbeat] heart_signal_failed user_id=#{user_id} " \
          "error=#{e.class}",
        )
        [nil, "read_error"]
      end

      def signal_unstable_seconds
        unstable = SiteSetting.interactive_heartbeat_signal_unstable_seconds.to_i
        lost = signal_lost_seconds
        [[unstable, 2].max, lost - 1].min
      end

      def signal_lost_seconds
        [SiteSetting.interactive_heartbeat_signal_stale_seconds.to_i, 6].max
      end

      def heartrate_runtime_ready?
        defined?(::LiveMetrics::ProviderAccount) &&
          defined?(::LiveMetrics::CurrentStateStore) &&
          defined?(::LiveMetrics::RefreshCoordinator) &&
          ::LiveMetrics::RefreshCoordinator.async_enabled?
      end

      def inactive_payload(session, reason)
        {
          active: false,
          status: session.reload.status,
          reason: reason,
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
        (Time.zone.now.to_f * 1000).to_i
      end
    end
  end
end
