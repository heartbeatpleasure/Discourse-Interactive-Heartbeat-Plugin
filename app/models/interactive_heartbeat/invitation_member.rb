# frozen_string_literal: true

module ::InteractiveHeartbeat
  class InvitationMember < ::ActiveRecord::Base
    self.table_name = "interactive_heartbeat_invitation_members"

    KIND_APPROVED = "approved"
    KIND_BLOCKED = "blocked"
    KINDS = [KIND_APPROVED, KIND_BLOCKED].freeze

    belongs_to :owner_user, class_name: "::User"
    belongs_to :member_user, class_name: "::User"

    validates :kind, presence: true, inclusion: { in: KINDS }
    validates :member_user_id, uniqueness: { scope: :owner_user_id }
    validate :member_must_differ_from_owner

    scope :approved, -> { where(kind: KIND_APPROVED) }
    scope :blocked, -> { where(kind: KIND_BLOCKED) }

    def self.set!(owner:, member:, kind:)
      row = find_or_initialize_by(owner_user_id: owner.id, member_user_id: member.id)
      row.kind = kind.to_s
      row.save!
      row
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    private

    def member_must_differ_from_owner
      errors.add(:member_user_id, "cannot be your own account") if owner_user_id == member_user_id
    end
  end
end
