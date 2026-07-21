# frozen_string_literal: true

module ::InteractiveHeartbeat
  class IntensityMapper
    class << self
      def for(participant:, input_bpm: nil, sync_score: nil)
        if sync_score.present?
          return sync_payload(participant, sync_score)
        end

        bpm = input_bpm.to_i
        case participant.response_mode
        when ::InteractiveHeartbeat::Participant::RESPONSE_ZONES
          zone_payload(participant, bpm)
        when ::InteractiveHeartbeat::Participant::RESPONSE_SMOOTH
          smooth_payload(participant, bpm)
        when ::InteractiveHeartbeat::Participant::RESPONSE_RELATIVE
          relative_payload(participant, bpm)
        else
          fixed_payload(participant, bpm)
        end
      end

      private

      def fixed_payload(participant, bpm)
        base_payload(participant, bpm).merge(
          mode: ::InteractiveHeartbeat::Participant::RESPONSE_FIXED,
          desired_strength: participant.pulse_strength,
          zone_key: "fixed",
        )
      end

      def zone_payload(participant, bpm)
        zone_key, strength =
          if bpm <= participant.zone_low_max_bpm
            ["low", participant.zone_low_intensity]
          elsif bpm <= participant.zone_medium_max_bpm
            ["medium", participant.zone_medium_intensity]
          elsif bpm <= participant.zone_high_max_bpm
            ["high", participant.zone_high_intensity]
          else
            ["peak", participant.zone_peak_intensity]
          end

        base_payload(participant, bpm).merge(
          mode: ::InteractiveHeartbeat::Participant::RESPONSE_ZONES,
          desired_strength: strength,
          zone_key: zone_key,
          zone_thresholds: [
            participant.zone_low_max_bpm,
            participant.zone_medium_max_bpm,
            participant.zone_high_max_bpm,
          ],
          zone_intensities: {
            low: participant.zone_low_intensity,
            medium: participant.zone_medium_intensity,
            high: participant.zone_high_intensity,
            peak: participant.zone_peak_intensity,
          },
        )
      end

      def smooth_payload(participant, bpm)
        ratio = normalized_ratio(bpm, participant.smooth_min_bpm, participant.smooth_max_bpm)
        strength = interpolate(participant.min_intensity, participant.max_intensity, ratio)

        base_payload(participant, bpm).merge(
          mode: ::InteractiveHeartbeat::Participant::RESPONSE_SMOOTH,
          desired_strength: strength,
          range_min_bpm: participant.smooth_min_bpm,
          range_max_bpm: participant.smooth_max_bpm,
          normalized_value: ratio.round(4),
          zone_key: "smooth",
        )
      end

      def relative_payload(participant, bpm)
        maximum_bpm = participant.baseline_bpm + participant.relative_range_bpm
        ratio = normalized_ratio(bpm, participant.baseline_bpm, maximum_bpm)
        strength = interpolate(participant.min_intensity, participant.max_intensity, ratio)

        base_payload(participant, bpm).merge(
          mode: ::InteractiveHeartbeat::Participant::RESPONSE_RELATIVE,
          desired_strength: strength,
          range_min_bpm: participant.baseline_bpm,
          range_max_bpm: maximum_bpm,
          normalized_value: ratio.round(4),
          zone_key: "relative",
        )
      end

      def sync_payload(participant, sync_score)
        score = [[sync_score.to_f, 0.0].max, 100.0].min
        ratio = score / 100.0
        strength = interpolate(participant.min_intensity, participant.max_intensity, ratio)

        base_payload(participant, nil).merge(
          mode: "sync",
          desired_strength: strength,
          sync_score: score.round,
          normalized_value: ratio.round(4),
          zone_key: sync_zone(score),
        )
      end

      def base_payload(participant, bpm)
        {
          input_bpm: bpm.presence,
          min_intensity: participant.min_intensity,
          max_intensity: participant.max_intensity,
          pulse_duration_ms: participant.pulse_duration_ms,
          ramp_up_per_second: participant.ramp_up_per_second,
          ramp_down_per_second: participant.ramp_down_per_second,
          hysteresis_bpm: participant.hysteresis_bpm,
        }
      end

      def normalized_ratio(value, minimum, maximum)
        return 0.0 if maximum <= minimum

        [[(value.to_f - minimum) / (maximum - minimum), 0.0].max, 1.0].min
      end

      def interpolate(minimum, maximum, ratio)
        [[(minimum + ((maximum - minimum) * ratio)).round, minimum].max, maximum].min
      end

      def sync_zone(score)
        return "synced" if score >= 85
        return "close" if score >= 55
        return "apart" if score >= 20

        "distant"
      end
    end
  end
end
