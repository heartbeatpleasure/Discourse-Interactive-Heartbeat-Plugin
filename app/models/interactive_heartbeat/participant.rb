# frozen_string_literal: true

module ::InteractiveHeartbeat
  class Participant < ::ActiveRecord::Base
    self.table_name = "interactive_heartbeat_participants"

    ROLE_INITIATOR = "initiator"
    ROLE_INVITEE = "invitee"
    ROLES = [ROLE_INITIATOR, ROLE_INVITEE].freeze

    RESPONSE_FIXED = "fixed"
    RESPONSE_ZONES = "zones"
    RESPONSE_SMOOTH = "smooth"
    RESPONSE_RELATIVE = "relative"
    RESPONSE_MODES = [RESPONSE_FIXED, RESPONSE_ZONES, RESPONSE_SMOOTH, RESPONSE_RELATIVE].freeze

    DEFAULT_MAX_INTENSITY = 12
    DEFAULT_MIN_INTENSITY = 3
    DEFAULT_PULSE_STRENGTH = 12
    DEFAULT_PULSE_DURATION_MS = 180
    DEFAULT_ZONE_LOW_MAX_BPM = 79
    DEFAULT_ZONE_MEDIUM_MAX_BPM = 99
    DEFAULT_ZONE_HIGH_MAX_BPM = 119
    DEFAULT_SMOOTH_MIN_BPM = 70
    DEFAULT_SMOOTH_MAX_BPM = 130
    DEFAULT_BASELINE_BPM = 70
    DEFAULT_RELATIVE_RANGE_BPM = 50
    DEFAULT_RAMP_UP_PER_SECOND = 2
    DEFAULT_RAMP_DOWN_PER_SECOND = 4
    DEFAULT_HYSTERESIS_BPM = 3

    belongs_to :session,
               class_name: "::InteractiveHeartbeat::Session",
               inverse_of: :participants
    belongs_to :user

    validates :role, presence: true, inclusion: { in: ROLES }
    validates :user_id, uniqueness: { scope: :session_id }

    before_validation :normalize_settings

    def settings_hash
      value = self[:settings]
      value.is_a?(Hash) ? value.with_indifferent_access : {}.with_indifferent_access
    end

    def accepted?
      accepted_at.present? && declined_at.blank?
    end

    def heartbeat_consent?
      heartbeat_consent_at.present?
    end

    def toy_consent?
      toy_consent_at.present?
    end

    def ready?
      ready_at.present?
    end

    def present_now?
      return false if presence_at.blank?

      presence_at >= SiteSetting.interactive_heartbeat_presence_timeout_seconds.to_i.seconds.ago
    end

    def accepted_configuration_revision
      value = Integer(settings_hash[:accepted_configuration_revision], exception: false)
      value&.positive? ? value : nil
    end

    def configuration_accepted?
      return false if session.blank?
      return false if settings_hash[:configuration_consent_revoked] == true

      accepted_configuration_revision == session.configuration_revision ||
        (accepted_configuration_revision.nil? && session.configuration_revision == 1)
    end

    def response_mode
      value = settings_hash[:response_mode].to_s
      RESPONSE_MODES.include?(value) ? value : RESPONSE_FIXED
    end

    def max_intensity
      bounded_integer(settings_hash[:max_intensity], 1, 20, DEFAULT_MAX_INTENSITY)
    end

    def min_intensity
      bounded_integer(settings_hash[:min_intensity], 1, max_intensity, [DEFAULT_MIN_INTENSITY, max_intensity].min)
    end

    def pulse_strength
      bounded_integer(settings_hash[:pulse_strength], 1, max_intensity, [DEFAULT_PULSE_STRENGTH, max_intensity].min)
    end

    def pulse_duration_ms
      bounded_integer(settings_hash[:pulse_duration_ms], 100, 500, DEFAULT_PULSE_DURATION_MS)
    end

    def zone_low_max_bpm
      bounded_integer(settings_hash[:zone_low_max_bpm], 45, 180, DEFAULT_ZONE_LOW_MAX_BPM)
    end

    def zone_medium_max_bpm
      bounded_integer(
        settings_hash[:zone_medium_max_bpm],
        zone_low_max_bpm + 5,
        200,
        [DEFAULT_ZONE_MEDIUM_MAX_BPM, zone_low_max_bpm + 5].max,
      )
    end

    def zone_high_max_bpm
      bounded_integer(
        settings_hash[:zone_high_max_bpm],
        zone_medium_max_bpm + 5,
        215,
        [DEFAULT_ZONE_HIGH_MAX_BPM, zone_medium_max_bpm + 5].max,
      )
    end

    def zone_low_intensity
      bounded_integer(settings_hash[:zone_low_intensity], min_intensity, max_intensity, min_intensity)
    end

    def zone_medium_intensity
      bounded_integer(
        settings_hash[:zone_medium_intensity],
        zone_low_intensity,
        max_intensity,
        [8, zone_low_intensity].max.clamp(zone_low_intensity, max_intensity),
      )
    end

    def zone_high_intensity
      bounded_integer(
        settings_hash[:zone_high_intensity],
        zone_medium_intensity,
        max_intensity,
        [11, zone_medium_intensity].max.clamp(zone_medium_intensity, max_intensity),
      )
    end

    def zone_peak_intensity
      bounded_integer(
        settings_hash[:zone_peak_intensity],
        zone_high_intensity,
        max_intensity,
        max_intensity,
      )
    end

    def smooth_min_bpm
      bounded_integer(settings_hash[:smooth_min_bpm], 40, 180, DEFAULT_SMOOTH_MIN_BPM)
    end

    def smooth_max_bpm
      bounded_integer(
        settings_hash[:smooth_max_bpm],
        smooth_min_bpm + 10,
        220,
        [DEFAULT_SMOOTH_MAX_BPM, smooth_min_bpm + 10].max,
      )
    end

    def baseline_bpm
      bounded_integer(settings_hash[:baseline_bpm], 40, 180, DEFAULT_BASELINE_BPM)
    end

    def relative_range_bpm
      bounded_integer(settings_hash[:relative_range_bpm], 10, 120, DEFAULT_RELATIVE_RANGE_BPM)
    end

    def ramp_up_per_second
      bounded_integer(settings_hash[:ramp_up_per_second], 1, 20, DEFAULT_RAMP_UP_PER_SECOND)
    end

    def ramp_down_per_second
      bounded_integer(settings_hash[:ramp_down_per_second], 1, 20, DEFAULT_RAMP_DOWN_PER_SECOND)
    end

    def hysteresis_bpm
      bounded_integer(settings_hash[:hysteresis_bpm], 0, 10, DEFAULT_HYSTERESIS_BPM)
    end

    def session_permission_scope?
      settings_hash[:permission_scope].to_s == "session"
    end

    def session_permissions_granted?
      return false if session&.terminal?
      return false unless session_permission_scope?
      return false unless heartbeat_consent?
      return false if session&.toy_required_for?(user_id) && !toy_consent?

      configuration_accepted?
    end

    def missing_session_permissions
      missing = []
      missing << "heartbeat" unless heartbeat_consent?
      missing << "toy" if session&.toy_required_for?(user_id) && !toy_consent?
      missing << "configuration" unless configuration_accepted?
      missing
    end

    def grant_session_permissions!(settings: {})
      now = Time.zone.now
      previous = [
        heartbeat_consent?,
        toy_consent?,
        configuration_accepted?,
        response_settings_payload,
        session_permission_scope?,
      ]

      merged_settings = settings_hash.to_h.merge(external_settings_hash(settings))
      merged_settings["permission_scope"] = "session"
      assign_attributes(
        heartbeat_consent_at: heartbeat_consent_at || now,
        toy_consent_at: session&.toy_required_for?(user_id) ? (toy_consent_at || now) : toy_consent_at,
        ready_at: nil,
        settings: normalized_settings(merged_settings),
      )
      set_configuration_consent!(true, save: false)
      save!

      current = [
        heartbeat_consent?,
        toy_consent?,
        configuration_accepted?,
        response_settings_payload,
        session_permission_scope?,
      ]
      session.pause! if session.status == ::InteractiveHeartbeat::Session::STATUS_ACTIVE && previous != current
      self
    end

    def revoke_session_permissions!
      was_active = session.status == ::InteractiveHeartbeat::Session::STATUS_ACTIVE
      updated = settings_hash.to_h
      updated.delete("permission_scope")
      assign_attributes(
        heartbeat_consent_at: nil,
        toy_consent_at: nil,
        ready_at: nil,
        settings: normalized_settings(updated),
      )
      set_configuration_consent!(false, save: false)
      save!
      session.pause! if was_active
      self
    end

    def response_settings_payload
      {
        response_mode: response_mode,
        max_intensity: max_intensity,
        min_intensity: min_intensity,
        pulse_strength: pulse_strength,
        pulse_duration_ms: pulse_duration_ms,
        zone_low_max_bpm: zone_low_max_bpm,
        zone_medium_max_bpm: zone_medium_max_bpm,
        zone_high_max_bpm: zone_high_max_bpm,
        zone_low_intensity: zone_low_intensity,
        zone_medium_intensity: zone_medium_intensity,
        zone_high_intensity: zone_high_intensity,
        zone_peak_intensity: zone_peak_intensity,
        smooth_min_bpm: smooth_min_bpm,
        smooth_max_bpm: smooth_max_bpm,
        baseline_bpm: baseline_bpm,
        relative_range_bpm: relative_range_bpm,
        ramp_up_per_second: ramp_up_per_second,
        ramp_down_per_second: ramp_down_per_second,
        hysteresis_bpm: hysteresis_bpm,
      }
    end

    def set_configuration_consent!(accepted, revision: session&.configuration_revision, save: true)
      updated = settings_hash.to_h
      if accepted && revision.to_i.positive?
        updated["accepted_configuration_revision"] = revision.to_i
        updated.delete("configuration_consent_revoked")
      else
        updated.delete("accepted_configuration_revision")
        updated["configuration_consent_revoked"] = true
      end
      self.settings = normalized_settings(updated)
      save! if save
      self
    end

    def update_preferences!(heartbeat_consent:, toy_consent:, configuration_consent:, ready:, settings:)
      previous_permissions = [
        heartbeat_consent?,
        toy_consent?,
        configuration_accepted?,
      ]
      was_ready = ready?
      now = Time.zone.now

      merged_settings = settings_hash.to_h.merge(external_settings_hash(settings))
      assign_attributes(
        heartbeat_consent_at: heartbeat_consent ? (heartbeat_consent_at || now) : nil,
        toy_consent_at: toy_consent ? (toy_consent_at || now) : nil,
        settings: normalized_settings(merged_settings),
      )
      unless configuration_consent.nil?
        set_configuration_consent!(configuration_consent, save: false)
      end

      permissions_changed = previous_permissions != [
        heartbeat_consent?,
        toy_consent?,
        configuration_accepted?,
      ]
      self.ready_at =
        if ready && configuration_accepted? && heartbeat_consent_or_not_required? && toy_consent_or_not_required?
          ready_at || now
        end
      save!

      if session.status == ::InteractiveHeartbeat::Session::STATUS_ACTIVE &&
           (permissions_changed || (was_ready && !ready?))
        session.pause!
      end
    end

    private

    def heartbeat_consent_or_not_required?
      !session.heartbeat_required_for?(user_id) || heartbeat_consent?
    end

    def toy_consent_or_not_required?
      !session.toy_required_for?(user_id) || toy_consent?
    end

    def normalize_settings
      self.settings = normalized_settings(settings_hash)
    end

    def external_settings_hash(value)
      if value.is_a?(ActionController::Parameters)
        value.to_unsafe_h
      elsif value.respond_to?(:to_h)
        value.to_h
      else
        {}
      end.stringify_keys.except("accepted_configuration_revision")
    end

    def normalized_settings(value)
      input =
        if value.is_a?(ActionController::Parameters)
          value.to_unsafe_h
        elsif value.respond_to?(:to_h)
          value.to_h
        else
          {}
        end.with_indifferent_access

      max_value = bounded_integer(input[:max_intensity], 1, 20, default_max_intensity)
      min_value = bounded_integer(input[:min_intensity], 1, max_value, [DEFAULT_MIN_INTENSITY, max_value].min)
      fixed_value = bounded_integer(input[:pulse_strength], 1, max_value, [default_pulse_strength, max_value].min)
      low_max = bounded_integer(input[:zone_low_max_bpm], 45, 180, DEFAULT_ZONE_LOW_MAX_BPM)
      medium_max = bounded_integer(
        input[:zone_medium_max_bpm],
        low_max + 5,
        200,
        [DEFAULT_ZONE_MEDIUM_MAX_BPM, low_max + 5].max,
      )
      high_max = bounded_integer(
        input[:zone_high_max_bpm],
        medium_max + 5,
        215,
        [DEFAULT_ZONE_HIGH_MAX_BPM, medium_max + 5].max,
      )
      low_strength = bounded_integer(input[:zone_low_intensity], min_value, max_value, min_value)
      medium_strength = bounded_integer(input[:zone_medium_intensity], low_strength, max_value, [8, low_strength].max)
      high_strength = bounded_integer(input[:zone_high_intensity], medium_strength, max_value, [11, medium_strength].max)
      peak_strength = bounded_integer(input[:zone_peak_intensity], high_strength, max_value, max_value)
      min_bpm = bounded_integer(input[:smooth_min_bpm], 40, 180, DEFAULT_SMOOTH_MIN_BPM)
      max_bpm = bounded_integer(
        input[:smooth_max_bpm],
        min_bpm + 10,
        220,
        [DEFAULT_SMOOTH_MAX_BPM, min_bpm + 10].max,
      )
      response = input[:response_mode].to_s
      response = RESPONSE_FIXED unless RESPONSE_MODES.include?(response)

      output = {
        "response_mode" => response,
        "max_intensity" => max_value,
        "min_intensity" => min_value,
        "pulse_strength" => fixed_value,
        "pulse_duration_ms" => bounded_integer(
          input[:pulse_duration_ms],
          100,
          500,
          default_pulse_duration_ms,
        ),
        "zone_low_max_bpm" => low_max,
        "zone_medium_max_bpm" => medium_max,
        "zone_high_max_bpm" => high_max,
        "zone_low_intensity" => low_strength,
        "zone_medium_intensity" => medium_strength,
        "zone_high_intensity" => high_strength,
        "zone_peak_intensity" => peak_strength,
        "smooth_min_bpm" => min_bpm,
        "smooth_max_bpm" => max_bpm,
        "baseline_bpm" => bounded_integer(input[:baseline_bpm], 40, 180, DEFAULT_BASELINE_BPM),
        "relative_range_bpm" => bounded_integer(
          input[:relative_range_bpm],
          10,
          120,
          DEFAULT_RELATIVE_RANGE_BPM,
        ),
        "ramp_up_per_second" => bounded_integer(
          input[:ramp_up_per_second],
          1,
          20,
          DEFAULT_RAMP_UP_PER_SECOND,
        ),
        "ramp_down_per_second" => bounded_integer(
          input[:ramp_down_per_second],
          1,
          20,
          DEFAULT_RAMP_DOWN_PER_SECOND,
        ),
        "hysteresis_bpm" => bounded_integer(
          input[:hysteresis_bpm],
          0,
          10,
          DEFAULT_HYSTERESIS_BPM,
        ),
      }
      accepted_revision = Integer(input[:accepted_configuration_revision], exception: false)
      output["accepted_configuration_revision"] = accepted_revision if accepted_revision&.positive?
      output["configuration_consent_revoked"] = true if input[:configuration_consent_revoked] == true
      output["permission_scope"] = "session" if input[:permission_scope].to_s == "session"
      output
    end

    def default_max_intensity
      value = SiteSetting.interactive_heartbeat_default_pulse_strength.to_i
      value.between?(1, 20) ? value : DEFAULT_MAX_INTENSITY
    end

    def default_pulse_strength
      default_max_intensity
    end

    def default_pulse_duration_ms
      value = SiteSetting.interactive_heartbeat_default_pulse_duration_ms.to_i
      value.between?(100, 500) ? value : DEFAULT_PULSE_DURATION_MS
    end

    def bounded_integer(value, min, max, fallback)
      parsed = Integer(value, exception: false)
      parsed = fallback unless parsed
      [[parsed, min].max, max].min
    end
  end
end
