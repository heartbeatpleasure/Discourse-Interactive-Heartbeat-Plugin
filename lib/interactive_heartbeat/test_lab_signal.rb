# frozen_string_literal: true

module ::InteractiveHeartbeat
  class TestLabSignal
    MIN_HEART_RATE = 30
    MAX_HEART_RATE = 220
    MIN_INTERVAL_MS = 273
    MAX_INTERVAL_MS = 2000
    MIN_COMMAND_GAP_MS = 140
    SIMULATED_VALID_FOR_MS = 5_000

    class << self
      def for(user:, parameters:)
        input = normalized_hash(parameters)
        mode = normalized_mode(input["mode"])
        source_a = source_for(user, "A", input["source_a_kind"], input["source_a_bpm"])
        source_b = source_for(user, "B", input["source_b_kind"], input["source_b_bpm"])
        plan = control_plan(mode, source_a, source_b, input["leader_source"])
        return inactive_payload(plan[:reason]) if plan[:reason].present?

        profile = ::InteractiveHeartbeat::Participant.new(settings: response_settings(input["settings"]))
        profile.valid?
        response = ::InteractiveHeartbeat::IntensityMapper.for(
          participant: profile,
          input_bpm: plan[:intensity_bpm],
          sync_score: plan[:sync_score],
        )
        interval_ms = interval_for(plan[:tempo_bpm])
        used_sources = plan[:used_sources]
        oldest_age_ms = used_sources.map { |source| source[:age_ms] }.max.to_i
        lost_after_ms = signal_lost_seconds * 1000
        unstable_after_ms = [signal_unstable_seconds * 1000, lost_after_ms - 1000].min
        valid_for_ms = if used_sources.any? { |source| source[:kind] == "real" }
          [lost_after_ms - oldest_age_ms, 0].max
        else
          SIMULATED_VALID_FOR_MS
        end
        return inactive_payload("no_fresh_heartbeat") if valid_for_ms <= 0

        now_ms = current_time_ms
        {
          active: true,
          test_lab: true,
          mode: mode,
          signal_state: oldest_age_ms >= unstable_after_ms ? "unstable" : "live",
          source: {
            username: plan[:label],
            heart_rate: plan[:tempo_bpm],
          },
          sources: [source_a, source_b].compact.map do |source|
            {
              key: source[:key],
              username: source[:label],
              kind: source[:kind],
              heart_rate: source[:heart_rate],
              age_ms: source[:age_ms],
            }
          end,
          control: {
            tempo_bpm: plan[:tempo_bpm],
            intensity_bpm: plan[:intensity_bpm],
            sync_score: plan[:sync_score],
            heartbeat_difference: plan[:heartbeat_difference],
            leader_source: plan[:leader_source],
          }.compact,
          response: response,
          pulse: {
            interval_ms: interval_ms,
            strength: response[:desired_strength],
            desired_strength: response[:desired_strength],
            duration_ms: [
              profile.pulse_duration_ms,
              [interval_ms - MIN_COMMAND_GAP_MS, 100].max,
            ].min,
            ramp_up_per_second: profile.ramp_up_per_second,
            ramp_down_per_second: profile.ramp_down_per_second,
            response_mode: response[:mode],
            zone_key: response[:zone_key],
          },
          measured_at_ms: used_sources.map { |source| source[:measured_at_ms] }.min,
          source_age_ms: oldest_age_ms,
          unstable_after_ms: unstable_after_ms,
          lost_after_ms: lost_after_ms,
          valid_for_ms: valid_for_ms,
          expires_at_ms: now_ms + valid_for_ms,
          server_time_ms: now_ms,
        }
      rescue => e
        Rails.logger.warn(
          "[interactive_heartbeat] test_lab_signal_failed user_id=#{user&.id} " \
          "error=#{e.class}",
        )
        inactive_payload("signal_temporarily_unavailable")
      end

      private

      def normalized_hash(value)
        if value.is_a?(ActionController::Parameters)
          value.to_unsafe_h
        elsif value.respond_to?(:to_h)
          value.to_h
        else
          {}
        end.stringify_keys
      end

      def normalized_mode(value)
        mode = value.to_s
        ::InteractiveHeartbeat::Session::PUBLIC_MODES.include?(mode) ? mode : ::InteractiveHeartbeat::Session::MODE_CROSS_HEARTBEAT
      end

      def source_for(user, key, kind, bpm)
        source_kind = kind.to_s
        return nil if source_kind == "unavailable"
        return real_source(user, key) if source_kind == "real" && key == "A"

        simulated_source(key, bpm)
      end

      def simulated_source(key, bpm)
        heart_rate = bounded_integer(bpm, MIN_HEART_RATE, MAX_HEART_RATE, key == "A" ? 75 : 95)
        now_ms = current_time_ms
        {
          key: key,
          label: "Source #{key}",
          kind: "simulated",
          heart_rate: heart_rate,
          measured_at_ms: now_ms,
          age_ms: 0,
        }
      end

      def real_source(user, key)
        return nil unless heartrate_runtime_ready?

        account = ::LiveMetrics::ProviderAccount.enabled_providers.active.find_by(user_id: user.id)
        return nil if account.blank? || !account.connected?

        state = ::LiveMetrics::CurrentStateStore.read(account)
        return nil unless ::LiveMetrics::CurrentStateStore.state_with_reading?(state)

        heart_rate = state[:heart_rate].to_i
        return nil unless heart_rate.between?(MIN_HEART_RATE, MAX_HEART_RATE)

        now_ms = current_time_ms
        measured_at_ms = state[:measured_at_ms].to_i
        {
          key: key,
          label: "Your live heartbeat",
          kind: "real",
          heart_rate: heart_rate,
          measured_at_ms: measured_at_ms,
          age_ms: [now_ms - measured_at_ms, 0].max,
        }
      rescue => e
        Rails.logger.warn(
          "[interactive_heartbeat] test_lab_real_source_failed user_id=#{user.id} " \
          "error=#{e.class}",
        )
        nil
      end

      def control_plan(mode, source_a, source_b, leader_source)
        sources = [source_a, source_b].compact
        missing = ->(reason = "source_missing") { { reason: reason } }

        case mode
        when ::InteractiveHeartbeat::Session::MODE_CROSS_HEARTBEAT
          return missing.call unless source_b
          plan(source_b[:heart_rate], source_b[:heart_rate], "Source B", [source_b])
        when ::InteractiveHeartbeat::Session::MODE_SHARED_CONTROL
          return missing.call unless source_a && source_b
          plan(source_b[:heart_rate], source_a[:heart_rate], "B tempo + A intensity", [source_a, source_b])
        when ::InteractiveHeartbeat::Session::MODE_HEART_SYNC
          return missing.call unless source_a && source_b
          difference = (source_a[:heart_rate] - source_b[:heart_rate]).abs
          score = [[100 - (difference * 3), 0].max, 100].min
          plan(
            average_rate(sources),
            nil,
            "A + B sync",
            sources,
            sync_score: score,
            heartbeat_difference: difference,
          )
        when ::InteractiveHeartbeat::Session::MODE_SHARED_AVERAGE
          return missing.call unless source_a && source_b
          average = average_rate(sources)
          plan(average, average, "A + B average", sources)
        when ::InteractiveHeartbeat::Session::MODE_HIGHEST_HEARTBEAT
          return missing.call if sources.empty?
          source = sources.max_by { |item| item[:heart_rate] }
          plan(source[:heart_rate], source[:heart_rate], "Highest heartbeat", [source])
        when ::InteractiveHeartbeat::Session::MODE_LOWEST_HEARTBEAT
          return missing.call if sources.empty?
          source = sources.min_by { |item| item[:heart_rate] }
          plan(source[:heart_rate], source[:heart_rate], "Lowest heartbeat", [source])
        when ::InteractiveHeartbeat::Session::MODE_LEADER_FOLLOWER
          leader_key = leader_source.to_s.upcase == "B" ? "B" : "A"
          source = leader_key == "B" ? source_b : source_a
          return missing.call unless source
          plan(
            source[:heart_rate],
            source[:heart_rate],
            "Source #{leader_key} (leader)",
            [source],
            leader_source: leader_key,
          )
        else
          missing.call("invalid_mode")
        end
      end

      def plan(tempo_bpm, intensity_bpm, label, used_sources, **extra)
        {
          tempo_bpm: tempo_bpm,
          intensity_bpm: intensity_bpm,
          label: label,
          used_sources: used_sources,
        }.merge(extra)
      end

      def response_settings(value)
        normalized_hash(value)
      end

      def average_rate(sources)
        (sources.sum { |source| source[:heart_rate] }.to_f / sources.length).round
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
      rescue
        false
      end

      def bounded_integer(value, minimum, maximum, fallback)
        parsed = Integer(value, exception: false)
        parsed = fallback unless parsed
        [[parsed, minimum].max, maximum].min
      end

      def inactive_payload(reason)
        {
          active: false,
          test_lab: true,
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
