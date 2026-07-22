# frozen_string_literal: true

module ::InteractiveHeartbeat
  class SessionNotifier
    NOTIFICATION_TYPE = :interactive_heartbeat

    EVENTS = %w[
      invitation
      invitation_accepted
      mode_approval
      mode_accepted
      both_ready
      session_declined
      session_ended
    ].freeze

    HIGH_PRIORITY_EVENTS = %w[invitation mode_approval both_ready].freeze

    class << self
      def notify!(session:, recipient:, actor:, event:, revision: nil)
        return if recipient.blank? || actor.blank? || recipient.id == actor.id
        return unless EVENTS.include?(event.to_s)
        return unless recipient.active? && !recipient.staged?

        event = event.to_s
        data = {
          event: event,
          session_token: session.token,
          url: "/interactive-heartbeat/sessions/#{session.token}",
          display_username: actor.username,
          actor_name: actor.name,
          mode: session.mode_key,
          revision: revision,
        }.compact

        scope = ::Notification.where(
          notification_type: ::Notification.types.fetch(NOTIFICATION_TYPE),
          user_id: recipient.id,
          read: false,
        ).where("data::json ->> 'session_token' = ?", session.token)
          .where("data::json ->> 'event' = ?", event)
        scope = scope.where("data::json ->> 'revision' = ?", revision.to_s) if revision.present?

        # Keep the notification list useful when the same state is saved repeatedly.
        return scope.order(id: :desc).first if scope.exists?

        notification = ::Notification.create!(
          notification_type: ::Notification.types.fetch(NOTIFICATION_TYPE),
          user_id: recipient.id,
          high_priority: HIGH_PRIORITY_EVENTS.include?(event),
          data: data.to_json,
        )
        recipient.publish_notifications_state
        notification
      rescue => e
        Rails.logger.warn(
          "[interactive_heartbeat] notification_failed " \
          "event=#{event} session_id=#{session&.id} recipient_id=#{recipient&.id} " \
          "error=#{e.class}",
        )
        nil
      end

      def clear_for!(user:, session_tokens:)
        tokens = Array(session_tokens).map(&:to_s).reject(&:blank?).uniq
        return 0 if user.blank? || tokens.blank?

        deleted = ::Notification.where(
          notification_type: ::Notification.types.fetch(NOTIFICATION_TYPE),
          user_id: user.id,
        ).where("data::json ->> 'session_token' IN (:tokens)", tokens: tokens).delete_all
        user.publish_notifications_state if deleted.positive?
        deleted
      rescue => e
        Rails.logger.warn(
          "[interactive_heartbeat] notification_cleanup_failed " \
          "user_id=#{user&.id} error=#{e.class}",
        )
        0
      end
    end
  end
end
