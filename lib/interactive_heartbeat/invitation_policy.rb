# frozen_string_literal: true

module ::InteractiveHeartbeat
  class InvitationPolicy
    Decision = Struct.new(:allowed, :reason, keyword_init: false)

    class << self
      def decision(sender:, recipient:)
        return Decision.new(false, :invalid_user) if sender.blank? || recipient.blank?
        return Decision.new(false, :same_user) if sender.id == recipient.id
        return Decision.new(false, :discourse_ignored) if ignored_between?(sender, recipient)

        rule = ::InteractiveHeartbeat::InvitationMember.find_by(
          owner_user_id: recipient.id,
          member_user_id: sender.id,
        )
        return Decision.new(false, :blocked) if rule&.kind == ::InteractiveHeartbeat::InvitationMember::KIND_BLOCKED

        mode = ::InteractiveHeartbeat::InvitationPreference.mode_for(recipient)
        case mode
        when ::InteractiveHeartbeat::InvitationPreference::MODE_APPROVED_MEMBERS
          Decision.new(
            rule&.kind == ::InteractiveHeartbeat::InvitationMember::KIND_APPROVED,
            :approval_required,
          )
        when ::InteractiveHeartbeat::InvitationPreference::MODE_NOBODY
          Decision.new(false, :nobody)
        else
          Decision.new(true, :allowed)
        end
      rescue => e
        Rails.logger.warn(
          "[interactive_heartbeat] invitation_policy_failed " \
          "sender_id=#{sender&.id} recipient_id=#{recipient&.id} error=#{e.class}",
        )
        Decision.new(false, :policy_error)
      end

      def allowed?(sender:, recipient:)
        decision(sender: sender, recipient: recipient).allowed
      end

      def cancel_disallowed_pending_invitations!(recipient:)
        return 0 if recipient.blank?

        cancelled = 0
        ::InteractiveHeartbeat::Session
          .where(
            invitee_id: recipient.id,
            status: ::InteractiveHeartbeat::Session::STATUS_INVITED,
          )
          .includes(:initiator, :participants)
          .find_each do |session|
            next if allowed?(sender: session.initiator, recipient: recipient)

            participant = session.participant_for(recipient)
            next if participant.blank?

            session.decline!(participant)
            ::InteractiveHeartbeat::SessionNotifier.clear_for!(
              user: recipient,
              session_tokens: [session.token],
            )
            cancelled += 1
          end
        cancelled
      end

      private

      def ignored_between?(first, second)
        first.ignored_user_ids.include?(second.id) || second.ignored_user_ids.include?(first.id)
      rescue => e
        Rails.logger.warn(
          "[interactive_heartbeat] discourse_ignore_check_failed " \
          "first_id=#{first&.id} second_id=#{second&.id} error=#{e.class}",
        )
        true
      end
    end
  end
end
