# frozen_string_literal: true

module Jobs
  module InteractiveHeartbeat
    class Cleanup < ::Jobs::Scheduled
      every 1.day
      sidekiq_options queue: "low", retry: false

      def execute(_args = nil)
        retention_days = SiteSetting.interactive_heartbeat_completed_session_retention_days.to_i
        return if retention_days <= 0
        return unless defined?(::InteractiveHeartbeat::Session)
        return unless ::InteractiveHeartbeat::Session.table_exists?

        cutoff = retention_days.days.ago
        scope = ::InteractiveHeartbeat::Session
          .where(status: ::InteractiveHeartbeat::Session::TERMINAL_STATUSES)
          .where(
            "COALESCE(interactive_heartbeat_sessions.ended_at, " \
            "interactive_heartbeat_sessions.updated_at) < ?",
            cutoff,
          )

        deleted = 0
        scope.in_batches(of: 100) do |batch|
          tokens = batch.pluck(:token)
          ::InteractiveHeartbeat::SessionNotifier.clear_all_for!(session_tokens: tokens)
          deleted += batch.count
          batch.destroy_all
        end

        ::InteractiveHeartbeat::AdminEventLog.record(
          category: :cleanup,
          event: :cleanup,
          result: deleted.positive? ? :success : :no_change,
          client_context: :server,
        )
      rescue => e
        Rails.logger.warn(
          "[interactive_heartbeat] completed_session_cleanup_failed error=#{e.class}",
        )
        ::InteractiveHeartbeat::AdminEventLog.record(
          category: :cleanup,
          event: :cleanup,
          result: :failed,
          severity: :error,
          client_context: :server,
        )
      end
    end
  end
end
