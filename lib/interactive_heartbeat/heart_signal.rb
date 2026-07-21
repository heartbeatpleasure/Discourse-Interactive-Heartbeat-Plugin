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
        return inactive_payload(session, "direction_disabled") unless session.target_enabled?(target_participant.user_id)
        return inactive_payload(session, "consent_missing") unless target_participant.toy_consent?
        return inactive_payload(session, "configuration_not_accepted") unless session.all_configuration_accepted?

        required_user_ids = session.required_heartbeat_user_ids
        return inactive_payload(session, "source_missing") if required_user_ids.blank?
        unless required_user_ids.all? { |user_id| session.participant_for(user_id)&.heartbeat_consent? }
          return inactive_payload(session, "consent_missing")
        end

        now_ms = current_time_ms
        readings, failure_reason = current_live_readings(required_user_ids, now_ms)
        if readings.blank?
          if %w[read_error signal_temporarily_unavailable].include?(failure_reason)
            return unavailable_payload(session, "signal_temporarily_unavailable")
          end

          session.pause!
          return unavailable_payload(session.reload, failure_reason || "no_fresh_heartbeat")
        end

        lost_after_ms = signal_lost_seconds * 1000
        unstable_after_ms = [signal_unstable_seconds * 1000, lost_after_ms - 1000].min
        oldest_age_ms = readings.values.map { |reading| reading[:age_ms] }.max.to_i
        if oldest_age_ms >= lost_after_ms
          session.pause!
          return unavailable_payload(session.reload, "no_fresh_heartbeat")
        end

        plan = control_plan(session, target_participant, readings)
        return inactive_payload(session, "source_missing") if plan.blank?

        response = ::InteractiveHeartbeat::IntensityMapper.for(
          participant: target_participant,
          input_bpm: plan[:intensity_bpm],
          sync_score: plan[:sync_score],
        )
        interval_ms = interval_for(plan[:tempo_bpm])
        valid_for_ms = [lost_after_ms - oldest_age_ms, 0].max
        measured_at_ms = readings.values.map { |reading| reading[:measured_at_ms] }.min

        {
          active: true,
          status: session.status,
          mode: session.mode_key,
          signal_state: oldest_age_ms >= unstable_after_ms ? "unstable" : "live",
          source: {
            username: plan[:label],
            heart_rate: session.settings_hash[:show_exact_bpm] ? plan[:tempo_bpm] : nil,
          },
          sources: readings.values.map do |reading|
            {
              username: reading[:user].username,
              heart_rate: session.settings_hash[:show_exact_bpm] ? reading[:heart_rate] : nil,
              age_ms: reading[:age_ms],
            }
          end,
          control: {
            tempo_bpm: plan[:tempo_bpm],
            intensity_bpm: plan[:intensity_bpm],
            sync_score: plan[:sync_score],
            heartbeat_difference: plan[:heartbeat_difference],
            leader_user_id: session.leader_user_id,
          }.compact,
          response: response,
          pulse: {
            interval_ms: interval_ms,
            strength: response[:desired_strength],
            desired_strength: response[:desired_strength],
            duration_ms: [
              target_participant.pulse_duration_ms,
              [interval_ms - MIN_COMMAND_GAP_MS, 100].max,
            ].min,
            ramp_up_per_second: target_participant.ramp_up_per_second,
            ramp_down_per_second: target_participant.ramp_down_per_second,
            response_mode: response[:mode],
            zone_key: response[:zone_key],
          },
          measured_at_ms: measured_at_ms,
          source_age_ms: oldest_age_ms,
          unstable_after_ms: unstable_after_ms,
          lost_after_ms: lost_after_ms,
          valid_for_ms: valid_for_ms,
          expires_at_ms: now_ms + valid_for_ms,
          server_time_ms: now_ms,
        }
      end

      private

      def control_plan(session, target_participant, readings)
        initiator = readings[session.initiator_id]
        invitee = readings[session.invitee_id]
        other = target_participant.user_id == session.initiator_id ? invitee : initiator
        own = readings[target_participant.user_id]
        all_rates = readings.values.map { |reading| reading[:heart_rate] }

        case session.mode_key
        when ::InteractiveHeartbeat::Session::MODE_CROSS_HEARTBEAT
          return nil if other.blank?

          {
            tempo_bpm: other[:heart_rate],
            intensity_bpm: other[:heart_rate],
            label: other[:user].username,
          }
        when ::InteractiveHeartbeat::Session::MODE_SHARED_CONTROL
          return nil if other.blank? || own.blank?

          {
            tempo_bpm: other[:heart_rate],
            intensity_bpm: own[:heart_rate],
            label: "#{other[:user].username} tempo + #{own[:user].username} intensity",
          }
        when ::InteractiveHeartbeat::Session::MODE_HEART_SYNC
          return nil if initiator.blank? || invitee.blank?

          difference = (initiator[:heart_rate] - invitee[:heart_rate]).abs
          score = [[100 - (difference * 3), 0].max, 100].min
          {
            tempo_bpm: average_rate(all_rates),
            sync_score: score,
            heartbeat_difference: difference,
            label: "#{initiator[:user].username} + #{invitee[:user].username}",
          }
        when ::InteractiveHeartbeat::Session::MODE_SHARED_AVERAGE
          average = average_rate(all_rates)
          {
            tempo_bpm: average,
            intensity_bpm: average,
            label: "#{session.initiator.username} + #{session.invitee.username} average",
          }
        when ::InteractiveHeartbeat::Session::MODE_HIGHEST_HEARTBEAT
          highest = readings.values.max_by { |reading| reading[:heart_rate] }
          {
            tempo_bpm: highest[:heart_rate],
            intensity_bpm: highest[:heart_rate],
            label: "Highest heartbeat",
          }
        when ::InteractiveHeartbeat::Session::MODE_LOWEST_HEARTBEAT
          lowest = readings.values.min_by { |reading| reading[:heart_rate] }
          {
            tempo_bpm: lowest[:heart_rate],
            intensity_bpm: lowest[:heart_rate],
            label: "Lowest heartbeat",
          }
        when ::InteractiveHeartbeat::Session::MODE_LEADER_FOLLOWER
          leader = readings[session.leader_user_id]
          return nil if leader.blank?

          {
            tempo_bpm: leader[:heart_rate],
            intensity_bpm: leader[:heart_rate],
            label: "#{leader[:user].username} (leader)",
          }
        end
      end

      def current_live_readings(user_ids, now_ms)
        readings = {}
        user_ids.each do |user_id|
          live, failure_reason = current_live_reading(user_id)
          return [nil, failure_reason] if live.blank?

          measured_at_ms = live[:measured_at_ms].to_i
          readings[user_id] = {
            user: ::User.find_by(id: user_id),
            heart_rate: live[:heart_rate].to_i,
            measured_at_ms: measured_at_ms,
            age_ms: [now_ms - measured_at_ms, 0].max,
          }
        end
        [readings, nil]
      end

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

      def average_rate(values)
        return nil if values.blank?

        (values.sum.to_f / values.length).round
      end

      def interval_for(heart_rate)
        [[(60_000.0 / heart_rate.to_i).round, MIN_INTERVAL_MS].max, MAX_INTERVAL_MS].min
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
