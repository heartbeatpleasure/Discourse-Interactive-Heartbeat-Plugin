# frozen_string_literal: true

module ::InteractiveHeartbeat
  class InvitationPreference < ::ActiveRecord::Base
    self.table_name = "interactive_heartbeat_invitation_preferences"

    MODE_ALL_MEMBERS = "all_members"
    MODE_APPROVED_MEMBERS = "approved_members"
    MODE_NOBODY = "nobody"
    MODES = [MODE_ALL_MEMBERS, MODE_APPROVED_MEMBERS, MODE_NOBODY].freeze

    belongs_to :user

    validates :user_id, uniqueness: true
    validates :mode, presence: true, inclusion: { in: MODES }

    def self.mode_for(user)
      return MODE_ALL_MEMBERS if user.blank?

      find_by(user_id: user.id)&.mode.presence || MODE_ALL_MEMBERS
    end

    def self.available_modes
      modes = [MODE_ALL_MEMBERS, MODE_APPROVED_MEMBERS]
      modes << MODE_NOBODY if SiteSetting.interactive_heartbeat_allow_nobody_invitation_preference
      modes
    end

    def self.update_mode!(user:, mode:)
      normalized = mode.to_s
      unless MODES.include?(normalized)
        record = new(user: user, mode: normalized)
        record.errors.add(:mode, "is invalid")
        raise ActiveRecord::RecordInvalid, record
      end
      if normalized == MODE_NOBODY && !SiteSetting.interactive_heartbeat_allow_nobody_invitation_preference
        record = new(user: user, mode: normalized)
        record.errors.add(:mode, "is not enabled by the administrator")
        raise ActiveRecord::RecordInvalid, record
      end

      row = find_or_initialize_by(user_id: user.id)
      row.mode = normalized
      row.save!
      row
    end
  end
end
