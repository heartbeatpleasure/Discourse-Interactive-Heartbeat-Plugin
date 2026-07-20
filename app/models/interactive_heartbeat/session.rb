# frozen_string_literal: true

module ::InteractiveHeartbeat
  class Session < ::ActiveRecord::Base
    self.table_name = "interactive_heartbeat_sessions"

    STATUS_INVITED = "invited"
    STATUS_SETUP = "setup"
    STATUS_ACTIVE = "active"
    STATUS_PAUSED = "paused"
    STATUS_DECLINED = "declined"
    STATUS_ENDED = "ended"
    STATUS_EXPIRED = "expired"
    STATUSES = [
      STATUS_INVITED,
      STATUS_SETUP,
      STATUS_ACTIVE,
      STATUS_PAUSED,
      STATUS_DECLINED,
      STATUS_ENDED,
      STATUS_EXPIRED,
    ].freeze

    MODE_HEARTBEAT_PULSE = "heartbeat_pulse"
    MODES = [MODE_HEARTBEAT_PULSE].freeze

    DIRECTION_INITIATOR_TO_INVITEE = "initiator_to_invitee"
    DIRECTION_INVITEE_TO_INITIATOR = "invitee_to_initiator"
    DIRECTIONS = [
      DIRECTION_INITIATOR_TO_INVITEE,
      DIRECTION_INVITEE_TO_INITIATOR,
    ].freeze

    belongs_to :initiator, class_name: "::User"
    belongs_to :invitee, class_name: "::User"
    has_many :participants,
             class_name: "::InteractiveHeartbeat::Participant",
             dependent: :destroy,
             inverse_of: :session

    validates :token, presence: true, uniqueness: true
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :mode, presence: true, inclusion: { in: MODES }
    validate :different_users
    validate :valid_directions

    scope :open, -> { where(status: [STATUS_INVITED, STATUS_SETUP, STATUS_ACTIVE, STATUS_PAUSED]) }

    before_validation :ensure_token, on: :create
    before_validation :normalize_settings

    def settings_hash
      value = self[:settings]
      value.is_a?(Hash) ? value.with_indifferent_access : {}.with_indifferent_access
    end

    def directions
      Array(settings_hash[:directions]).map(&:to_s).select { |value| DIRECTIONS.include?(value) }.uniq
    end

    def participant_for(user_or_id)
      user_id = user_or_id.respond_to?(:id) ? user_or_id.id : user_or_id
      participants.detect { |participant| participant.user_id == user_id.to_i } ||
        participants.find_by(user_id: user_id)
    end

    def other_participant(user_or_id)
      user_id = user_or_id.respond_to?(:id) ? user_or_id.id : user_or_id
      participants.detect { |participant| participant.user_id != user_id.to_i } ||
        participants.where.not(user_id: user_id).first
    end

    def participant?(user_or_id)
      participant_for(user_or_id).present?
    end

    def direction_enabled?(source_user_id, target_user_id)
      source_user_id = source_user_id.to_i
      target_user_id = target_user_id.to_i

      if source_user_id == initiator_id && target_user_id == invitee_id
        directions.include?(DIRECTION_INITIATOR_TO_INVITEE)
      elsif source_user_id == invitee_id && target_user_id == initiator_id
        directions.include?(DIRECTION_INVITEE_TO_INITIATOR)
      else
        false
      end
    end

    def expired?
      status == STATUS_EXPIRED || (status == STATUS_INVITED && expires_at <= Time.zone.now)
    end

    def terminal?
      [STATUS_DECLINED, STATUS_ENDED, STATUS_EXPIRED].include?(status)
    end

    def all_accepted?
      participants.size == 2 && participants.all?(&:accepted?)
    end

    def all_ready?
      participants.size == 2 && participants.all?(&:ready?)
    end

    def all_present?
      participants.size == 2 && participants.all?(&:present_now?)
    end

    def required_consents_satisfied?
      return false unless participants.size == 2

      directions.all? do |direction|
        source, target = participants_for_direction(direction)
        source&.heartbeat_consent? && target&.toy_consent?
      end
    end

    def startable?
      !terminal? && all_accepted? && all_ready? && all_present? && required_consents_satisfied?
    end

    def refresh_expiration!
      return false unless status == STATUS_INVITED && expires_at <= Time.zone.now

      update!(status: STATUS_EXPIRED, ended_at: Time.zone.now)
      true
    end

    def refresh_presence_state!
      return false unless status == STATUS_ACTIVE
      return false if all_present?

      transaction do
        lock!
        update!(status: STATUS_PAUSED)
        participants.update_all(ready_at: nil, updated_at: Time.zone.now)
      end
      true
    end

    def accept!(participant)
      raise ActiveRecord::RecordInvalid, self if terminal?

      transaction do
        lock!
        participant.lock!
        participant.update!(accepted_at: participant.accepted_at || Time.zone.now, declined_at: nil)
        update!(status: STATUS_SETUP) if participants.reload.all?(&:accepted?)
      end
    end

    def decline!(participant)
      transaction do
        lock!
        participant.lock!
        participant.update!(declined_at: Time.zone.now, ready_at: nil)
        update!(status: STATUS_DECLINED, ended_at: Time.zone.now)
        participants.where.not(id: participant.id).update_all(ready_at: nil, updated_at: Time.zone.now)
      end
    end

    def start!
      transaction do
        lock!
        participants.reload.each(&:lock!)
        raise ActiveRecord::RecordInvalid, self unless startable?

        update!(status: STATUS_ACTIVE, started_at: started_at || Time.zone.now, ended_at: nil)
      end
    end

    def pause!
      return if terminal?

      transaction do
        lock!
        update!(status: STATUS_PAUSED)
        participants.update_all(ready_at: nil, updated_at: Time.zone.now)
      end
    end

    def end!
      return if status == STATUS_ENDED

      transaction do
        lock!
        update!(status: STATUS_ENDED, ended_at: Time.zone.now)
        participants.update_all(ready_at: nil, updated_at: Time.zone.now)
      end
    end

    def end_for_user_cleanup!
      update_columns(status: STATUS_ENDED, ended_at: Time.zone.now, updated_at: Time.zone.now)
    end

    private

    def participants_for_direction(direction)
      case direction
      when DIRECTION_INITIATOR_TO_INVITEE
        [participant_for(initiator_id), participant_for(invitee_id)]
      when DIRECTION_INVITEE_TO_INITIATOR
        [participant_for(invitee_id), participant_for(initiator_id)]
      else
        [nil, nil]
      end
    end

    def ensure_token
      self.token ||= SecureRandom.uuid
    end

    def normalize_settings
      normalized = settings_hash.to_h
      normalized["directions"] = directions.presence || [DIRECTION_INITIATOR_TO_INVITEE]
      normalized["show_exact_bpm"] = false unless normalized.key?("show_exact_bpm")
      self.settings = normalized
    end

    def different_users
      errors.add(:invitee_id, "must be different from initiator") if initiator_id == invitee_id
    end

    def valid_directions
      values = Array(settings_hash[:directions]).map(&:to_s)
      errors.add(:settings, "must contain at least one valid direction") if (values & DIRECTIONS).blank?
      errors.add(:settings, "contains an invalid direction") if (values - DIRECTIONS).present?
    end
  end
end
