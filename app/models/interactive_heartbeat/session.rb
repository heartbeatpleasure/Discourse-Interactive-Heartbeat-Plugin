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
    OPEN_STATUSES = [STATUS_INVITED, STATUS_SETUP, STATUS_ACTIVE, STATUS_PAUSED].freeze
    TERMINAL_STATUSES = [STATUS_DECLINED, STATUS_ENDED, STATUS_EXPIRED].freeze
    STATUSES = (OPEN_STATUSES + TERMINAL_STATUSES).freeze

    LEGACY_MODE_HEARTBEAT_PULSE = "heartbeat_pulse"
    MODE_HEARTBEAT_PULSE = LEGACY_MODE_HEARTBEAT_PULSE
    MODE_CROSS_HEARTBEAT = "cross_heartbeat"
    MODE_SHARED_CONTROL = "shared_control"
    MODE_HEART_SYNC = "heart_sync"
    MODE_SHARED_AVERAGE = "shared_average"
    MODE_HIGHEST_HEARTBEAT = "highest_heartbeat"
    MODE_LOWEST_HEARTBEAT = "lowest_heartbeat"
    MODE_LEADER_FOLLOWER = "leader_follower"

    MODES = [
      LEGACY_MODE_HEARTBEAT_PULSE,
      MODE_CROSS_HEARTBEAT,
      MODE_SHARED_CONTROL,
      MODE_HEART_SYNC,
      MODE_SHARED_AVERAGE,
      MODE_HIGHEST_HEARTBEAT,
      MODE_LOWEST_HEARTBEAT,
      MODE_LEADER_FOLLOWER,
    ].freeze

    PUBLIC_MODES = [
      MODE_CROSS_HEARTBEAT,
      MODE_SHARED_CONTROL,
      MODE_HEART_SYNC,
      MODE_SHARED_AVERAGE,
      MODE_HIGHEST_HEARTBEAT,
      MODE_LOWEST_HEARTBEAT,
      MODE_LEADER_FOLLOWER,
    ].freeze

    BOTH_HEARTBEATS_MODES = [
      MODE_SHARED_CONTROL,
      MODE_HEART_SYNC,
      MODE_SHARED_AVERAGE,
      MODE_HIGHEST_HEARTBEAT,
      MODE_LOWEST_HEARTBEAT,
    ].freeze

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
    validate :valid_leader

    scope :open, -> { where(status: OPEN_STATUSES) }
    scope :terminal, -> { where(status: TERMINAL_STATUSES) }

    before_validation :ensure_token, on: :create
    before_validation :normalize_settings

    def settings_hash
      value = self[:settings]
      value.is_a?(Hash) ? value.with_indifferent_access : {}.with_indifferent_access
    end

    def mode_key
      mode == LEGACY_MODE_HEARTBEAT_PULSE ? MODE_CROSS_HEARTBEAT : mode
    end

    def directions
      Array(settings_hash[:directions]).map(&:to_s).select { |value| DIRECTIONS.include?(value) }.uniq
    end

    def configuration_revision
      value = Integer(settings_hash[:configuration_revision], exception: false)
      value&.positive? ? value : 1
    end

    def configuration_proposed_by_id
      Integer(settings_hash[:configuration_proposed_by_id], exception: false)
    end

    def leader_user_id
      return nil unless mode_key == MODE_LEADER_FOLLOWER

      value = Integer(settings_hash[:leader_user_id], exception: false)
      [initiator_id, invitee_id].include?(value) ? value : initiator_id
    end

    def leader
      return nil if leader_user_id.blank?

      leader_user_id == initiator_id ? initiator : invitee
    end

    def participant_for(user_or_id)
      user_id = participant_user_id(user_or_id)
      participants.detect { |participant| participant.user_id == user_id } ||
        participants.find_by(user_id: user_id)
    end

    def other_participant(user_or_id)
      user_id = participant_user_id(user_or_id)
      participants.detect { |participant| participant.user_id != user_id } ||
        participants.where.not(user_id: user_id).first
    end

    def participant?(user_or_id)
      participant_for(user_or_id).present?
    end

    def target_user_ids
      ids = []
      ids << invitee_id if directions.include?(DIRECTION_INITIATOR_TO_INVITEE)
      ids << initiator_id if directions.include?(DIRECTION_INVITEE_TO_INITIATOR)
      ids.uniq
    end

    def target_enabled?(user_or_id)
      target_user_ids.include?(participant_user_id(user_or_id))
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

    def required_heartbeat_user_ids
      case mode_key
      when MODE_CROSS_HEARTBEAT
        ids = []
        ids << initiator_id if directions.include?(DIRECTION_INITIATOR_TO_INVITEE)
        ids << invitee_id if directions.include?(DIRECTION_INVITEE_TO_INITIATOR)
        ids.uniq
      when *BOTH_HEARTBEATS_MODES
        [initiator_id, invitee_id]
      when MODE_LEADER_FOLLOWER
        [leader_user_id].compact
      else
        []
      end
    end

    def heartbeat_required_for?(user_or_id)
      required_heartbeat_user_ids.include?(participant_user_id(user_or_id))
    end

    def toy_required_for?(user_or_id)
      target_enabled?(user_or_id)
    end

    def configuration_accepted_by?(participant)
      participant&.configuration_accepted?
    end

    def all_configuration_accepted?
      participants.size == 2 && participants.all?(&:configuration_accepted?)
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

      heartbeat_ok = required_heartbeat_user_ids.all? do |user_id|
        participant_for(user_id)&.heartbeat_consent?
      end
      toy_ok = target_user_ids.all? do |user_id|
        participant_for(user_id)&.toy_consent?
      end

      heartbeat_ok && toy_ok
    end

    def startable?
      !terminal? && all_accepted? && all_configuration_accepted? && all_ready? && all_present? &&
        required_consents_satisfied?
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

    def propose_configuration!(participant:, requested_mode:, requested_leader_user_id: nil)
      canonical_mode = canonical_mode_value(requested_mode)
      participant = participant_for(participant)
      raise ActiveRecord::RecordInvalid, self unless PUBLIC_MODES.include?(canonical_mode)
      raise ActiveRecord::RecordInvalid, self if participant.blank?
      raise ActiveRecord::RecordInvalid, self unless participant.accepted?
      raise ActiveRecord::RecordInvalid, self if terminal?

      normalized_leader =
        if canonical_mode == MODE_LEADER_FOLLOWER
          candidate = Integer(requested_leader_user_id, exception: false)
          [initiator_id, invitee_id].include?(candidate) ? candidate : nil
        end
      if canonical_mode == MODE_LEADER_FOLLOWER && normalized_leader.blank?
        errors.add(:settings, "must select a valid leader")
        raise ActiveRecord::RecordInvalid, self
      end

      unchanged = mode_key == canonical_mode && leader_user_id == normalized_leader
      if unchanged
        participant.set_configuration_consent!(true)
        return false
      end

      transaction do
        lock!
        participants.reload.each(&:lock!)
        next_revision = configuration_revision + 1
        updated_settings = settings_hash.to_h
        updated_settings["configuration_revision"] = next_revision
        updated_settings["configuration_proposed_by_id"] = participant.user_id
        if canonical_mode == MODE_LEADER_FOLLOWER
          updated_settings["leader_user_id"] = normalized_leader
        else
          updated_settings.delete("leader_user_id")
        end

        self.mode = canonical_mode
        self.settings = updated_settings
        self.status = STATUS_PAUSED if [STATUS_ACTIVE, STATUS_PAUSED].include?(status)
        self.status = STATUS_SETUP if status == STATUS_SETUP
        save!

        participants.each do |row|
          row.set_configuration_consent!(row.id == participant.id, revision: next_revision, save: false)
          row.ready_at = nil
          row.save!
        end
      end
      true
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

    def participant_user_id(user_or_id)
      value =
        if user_or_id.is_a?(::InteractiveHeartbeat::Participant)
          user_or_id.user_id
        elsif user_or_id.respond_to?(:id)
          user_or_id.id
        else
          user_or_id
        end
      value.to_i
    end

    def canonical_mode_value(value)
      value.to_s == LEGACY_MODE_HEARTBEAT_PULSE ? MODE_CROSS_HEARTBEAT : value.to_s
    end

    def ensure_token
      self.token ||= SecureRandom.uuid
    end

    def normalize_settings
      normalized = settings_hash.to_h
      normalized["directions"] = directions.presence || [DIRECTION_INITIATOR_TO_INVITEE]
      normalized["show_exact_bpm"] = false unless normalized.key?("show_exact_bpm")
      normalized["configuration_revision"] = configuration_revision
      if canonical_mode_value(mode) == MODE_LEADER_FOLLOWER
        candidate = Integer(normalized["leader_user_id"], exception: false)
        normalized["leader_user_id"] = [initiator_id, invitee_id].include?(candidate) ? candidate : initiator_id
      else
        normalized.delete("leader_user_id")
      end
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

    def valid_leader
      return unless mode_key == MODE_LEADER_FOLLOWER
      return if [initiator_id, invitee_id].include?(leader_user_id)

      errors.add(:settings, "must select a participant as leader")
    end
  end
end
