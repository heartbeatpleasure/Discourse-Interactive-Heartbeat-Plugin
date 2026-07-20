# frozen_string_literal: true

module ::InteractiveHeartbeat
  class Participant < ::ActiveRecord::Base
    self.table_name = "interactive_heartbeat_participants"

    ROLE_INITIATOR = "initiator"
    ROLE_INVITEE = "invitee"
    ROLES = [ROLE_INITIATOR, ROLE_INVITEE].freeze

    DEFAULT_MAX_INTENSITY = 12
    DEFAULT_PULSE_STRENGTH = 12
    DEFAULT_PULSE_DURATION_MS = 180

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

    def max_intensity
      bounded_integer(settings_hash[:max_intensity], 1, 20, DEFAULT_MAX_INTENSITY)
    end

    def pulse_strength
      [bounded_integer(settings_hash[:pulse_strength], 1, 20, DEFAULT_PULSE_STRENGTH), max_intensity].min
    end

    def pulse_duration_ms
      bounded_integer(settings_hash[:pulse_duration_ms], 100, 500, DEFAULT_PULSE_DURATION_MS)
    end

    def update_preferences!(heartbeat_consent:, toy_consent:, ready:, settings:)
      previous = [heartbeat_consent?, toy_consent?, settings_hash.to_h]
      was_ready = ready?
      now = Time.zone.now

      assign_attributes(
        heartbeat_consent_at: heartbeat_consent ? (heartbeat_consent_at || now) : nil,
        toy_consent_at: toy_consent ? (toy_consent_at || now) : nil,
        settings: normalized_settings(settings),
      )

      changed_materially = previous != [heartbeat_consent?, toy_consent?, settings_hash.to_h]
      self.ready_at = ready && heartbeat_consent_or_not_required? && toy_consent_or_not_required? ? now : nil
      save!

      if session.status == ::InteractiveHeartbeat::Session::STATUS_ACTIVE &&
           (changed_materially || (was_ready && !ready?))
        session.pause!
      end
    end

    private

    def heartbeat_consent_or_not_required?
      session.directions.none? do |direction|
        (direction == ::InteractiveHeartbeat::Session::DIRECTION_INITIATOR_TO_INVITEE && role == ROLE_INITIATOR) ||
          (direction == ::InteractiveHeartbeat::Session::DIRECTION_INVITEE_TO_INITIATOR && role == ROLE_INVITEE)
      end || heartbeat_consent?
    end

    def toy_consent_or_not_required?
      session.directions.none? do |direction|
        (direction == ::InteractiveHeartbeat::Session::DIRECTION_INITIATOR_TO_INVITEE && role == ROLE_INVITEE) ||
          (direction == ::InteractiveHeartbeat::Session::DIRECTION_INVITEE_TO_INITIATOR && role == ROLE_INITIATOR)
      end || toy_consent?
    end

    def normalize_settings
      self.settings = normalized_settings(settings_hash)
    end

    def normalized_settings(value)
      input =
        if value.is_a?(ActionController::Parameters)
          value.to_unsafe_h
        elsif value.respond_to?(:to_h)
          value.to_h
        else
          {}
        end
      max_intensity = bounded_integer(input["max_intensity"] || input[:max_intensity], 1, 20, default_max_intensity)
      pulse_strength = bounded_integer(input["pulse_strength"] || input[:pulse_strength], 1, 20, default_pulse_strength)
      pulse_duration_ms = bounded_integer(
        input["pulse_duration_ms"] || input[:pulse_duration_ms],
        100,
        500,
        default_pulse_duration_ms,
      )

      {
        "max_intensity" => max_intensity,
        "pulse_strength" => [pulse_strength, max_intensity].min,
        "pulse_duration_ms" => pulse_duration_ms,
      }
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
      return fallback unless parsed

      [[parsed, min].max, max].min
    end
  end
end
