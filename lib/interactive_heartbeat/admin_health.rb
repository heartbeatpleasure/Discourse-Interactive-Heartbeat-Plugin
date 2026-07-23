# frozen_string_literal: true

module ::InteractiveHeartbeat
  class AdminHealth
    class << self
      def summary
        configuration = configuration_summary
        database = database_summary
        sessions = database[:ready] ? session_summary : unavailable_session_summary
        events = event_summary
        lovense = lovense_summary
        warnings = build_warnings(configuration, database, sessions, events)

        {
          generated_at: Time.zone.now.iso8601,
          overall: overall_summary(configuration, warnings),
          warnings: warnings,
          configuration: configuration,
          database: database,
          sessions: sessions,
          lovense: lovense,
          events: events,
          privacy: privacy_summary,
        }
      rescue => e
        Rails.logger.error(
          "[interactive_heartbeat] admin_health_summary_failed error=#{e.class}",
        )
        {
          generated_at: Time.zone.now.iso8601,
          overall: { state: "critical", severity: "critical" },
          warnings: [warning(:health_unavailable, :critical)],
          configuration: configuration_summary,
          database: database_summary,
          sessions: unavailable_session_summary,
          lovense: lovense_summary,
          events: event_summary,
          privacy: privacy_summary,
        }
      end

      private

      def configuration_summary
        {
          plugin_enabled: SiteSetting.interactive_heartbeat_enabled,
          navigation_enabled: SiteSetting.interactive_heartbeat_nav_enabled,
          test_lab_enabled: SiteSetting.interactive_heartbeat_test_lab_enabled,
          allowed_groups_count: setting_list(SiteSetting.interactive_heartbeat_allowed_groups).length,
          lovense_configured: ::InteractiveHeartbeat::LovenseClient.configured?,
          lovense_app_type: SiteSetting.interactive_heartbeat_lovense_app_type.to_s,
          callback_ttl_seconds: SiteSetting.interactive_heartbeat_lovense_callback_ttl_seconds.to_i,
          invite_expiry_minutes: SiteSetting.interactive_heartbeat_invite_expiry_minutes.to_i,
          allow_nobody_invitation_preference: SiteSetting.interactive_heartbeat_allow_nobody_invitation_preference,
          max_open_sessions_per_user: SiteSetting.interactive_heartbeat_max_open_sessions_per_user.to_i,
          declined_invite_cooldown_minutes: SiteSetting.interactive_heartbeat_declined_invite_cooldown_minutes.to_i,
          invites_per_day: SiteSetting.interactive_heartbeat_invites_per_day.to_i,
          max_invitation_list_members: SiteSetting.interactive_heartbeat_max_invitation_list_members.to_i,
          completed_session_retention_days: SiteSetting.interactive_heartbeat_completed_session_retention_days.to_i,
          presence_timeout_seconds: SiteSetting.interactive_heartbeat_presence_timeout_seconds.to_i,
          signal_unstable_seconds: SiteSetting.interactive_heartbeat_signal_unstable_seconds.to_i,
          signal_stale_seconds: SiteSetting.interactive_heartbeat_signal_stale_seconds.to_i,
          signal_poll_ms: SiteSetting.interactive_heartbeat_signal_poll_ms.to_i,
          heartrate_plugin_available: heartrate_plugin_available?,
          heartrate_plugin_enabled: site_setting_value(:live_metrics_enabled),
          async_current_readings_enabled: site_setting_value(:live_metrics_async_current_readings_enabled),
        }
      end

      def database_summary
        tables = {
          sessions: table_exists?("interactive_heartbeat_sessions"),
          participants: table_exists?("interactive_heartbeat_participants"),
          invitation_preferences: table_exists?("interactive_heartbeat_invitation_preferences"),
          invitation_members: table_exists?("interactive_heartbeat_invitation_members"),
        }
        dismissed_at = tables[:participants] && column_exists?("interactive_heartbeat_participants", "dismissed_at")

        {
          ready: tables.values.all? && dismissed_at,
          tables: tables,
          dismissed_at_column: dismissed_at,
          session_rows: safe_count(::InteractiveHeartbeat::Session),
          participant_rows: safe_count(::InteractiveHeartbeat::Participant),
          invitation_preference_rows: safe_count(::InteractiveHeartbeat::InvitationPreference),
          invitation_member_rows: safe_count(::InteractiveHeartbeat::InvitationMember),
        }
      rescue => e
        Rails.logger.warn(
          "[interactive_heartbeat] admin_health_database_failed error=#{e.class}",
        )
        {
          ready: false,
          tables: {},
          dismissed_at_column: false,
          session_rows: 0,
          participant_rows: 0,
          invitation_preference_rows: 0,
          invitation_member_rows: 0,
        }
      end

      def session_summary
        counts = ::InteractiveHeartbeat::Session.group(:status).count
        active_sessions = ::InteractiveHeartbeat::Session
          .where(status: ::InteractiveHeartbeat::Session::STATUS_ACTIVE)
          .includes(:participants)
          .to_a
        stale_active = active_sessions.count { |session| !session.all_present? }
        recent_terminal = ::InteractiveHeartbeat::Session
          .where(status: ::InteractiveHeartbeat::Session::TERMINAL_STATUSES)
          .where(
            "COALESCE(interactive_heartbeat_sessions.ended_at, interactive_heartbeat_sessions.updated_at) >= ?",
            24.hours.ago,
          )
          .count

        {
          available: true,
          open_total: ::InteractiveHeartbeat::Session.where(status: ::InteractiveHeartbeat::Session::OPEN_STATUSES).count,
          invited: counts.fetch(::InteractiveHeartbeat::Session::STATUS_INVITED, 0),
          setup: counts.fetch(::InteractiveHeartbeat::Session::STATUS_SETUP, 0),
          active: counts.fetch(::InteractiveHeartbeat::Session::STATUS_ACTIVE, 0),
          paused: counts.fetch(::InteractiveHeartbeat::Session::STATUS_PAUSED, 0),
          ended: counts.fetch(::InteractiveHeartbeat::Session::STATUS_ENDED, 0),
          declined: counts.fetch(::InteractiveHeartbeat::Session::STATUS_DECLINED, 0),
          expired: counts.fetch(::InteractiveHeartbeat::Session::STATUS_EXPIRED, 0),
          terminal_last_24h: recent_terminal,
          stale_active: stale_active,
        }
      rescue => e
        Rails.logger.warn(
          "[interactive_heartbeat] admin_health_sessions_failed error=#{e.class}",
        )
        unavailable_session_summary
      end

      def unavailable_session_summary
        {
          available: false,
          open_total: 0,
          invited: 0,
          setup: 0,
          active: 0,
          paused: 0,
          ended: 0,
          declined: 0,
          expired: 0,
          terminal_last_24h: 0,
          stale_active: 0,
        }
      end

      def lovense_summary
        {
          configured: ::InteractiveHeartbeat::LovenseClient.configured?,
          callback_ttl_seconds: ::InteractiveHeartbeat::LovenseCallbackStore.ttl_seconds,
          successful_callbacks_last_hour: ::InteractiveHeartbeat::AdminEventLog.count_since(
            since: 1.hour.ago,
            category: "lovense",
            event: "lovense_callback",
            result: "success",
          ),
          rejected_callbacks_last_hour: ::InteractiveHeartbeat::AdminEventLog.count_since(
            since: 1.hour.ago,
            category: "lovense",
            event: "lovense_callback",
            result: %w[rejected invalid rate_limited payload_too_large],
          ),
          token_errors_last_24h: ::InteractiveHeartbeat::AdminEventLog.count_since(
            since: 24.hours.ago,
            category: "lovense",
            event: "lovense_token",
            severity: "error",
          ),
        }
      rescue
        {
          configured: false,
          callback_ttl_seconds: SiteSetting.interactive_heartbeat_lovense_callback_ttl_seconds.to_i,
          successful_callbacks_last_hour: 0,
          rejected_callbacks_last_hour: 0,
          token_errors_last_24h: 0,
        }
      end

      def event_summary
        {
          total_count: ::InteractiveHeartbeat::AdminEventLog.total_count,
          warnings_last_24h: ::InteractiveHeartbeat::AdminEventLog.count_since(
            since: 24.hours.ago,
            severity: "warning",
          ),
          errors_last_24h: ::InteractiveHeartbeat::AdminEventLog.count_since(
            since: 24.hours.ago,
            severity: "error",
          ),
          retention_days: (::InteractiveHeartbeat::AdminEventLog::RETENTION_SECONDS / 1.day).to_i,
          max_events: ::InteractiveHeartbeat::AdminEventLog::MAX_EVENTS,
        }
      rescue
        { total_count: 0, warnings_last_24h: 0, errors_last_24h: 0, retention_days: 7, max_events: 500 }
      end

      def privacy_summary
        {
          heartbeat_history_stored: false,
          callback_state_storage: "latest_only_redis",
          callback_state_ttl_seconds: ::InteractiveHeartbeat::LovenseCallbackStore.ttl_seconds,
          event_log_payload: "bounded_metadata_only",
          event_log_identifiers_stored: false,
        }
      end

      def build_warnings(configuration, database, sessions, events)
        warnings = []
        unless configuration[:plugin_enabled]
          warnings << warning(:plugin_disabled, :info)
          return warnings
        end

        warnings << warning(:database_not_ready, :critical) unless database[:ready]
        warnings << warning(:heartrate_dependency_missing, :critical) unless configuration[:heartrate_plugin_available]
        if configuration[:heartrate_plugin_available] && !configuration[:heartrate_plugin_enabled]
          warnings << warning(:heartrate_dependency_disabled, :critical)
        end
        if configuration[:heartrate_plugin_available] && !configuration[:async_current_readings_enabled]
          warnings << warning(:async_current_readings_disabled, :critical)
        end
        warnings << warning(:lovense_not_configured, :warning) unless configuration[:lovense_configured]
        if sessions[:available] && sessions[:stale_active].to_i.positive?
          warnings << warning(:stale_active_sessions, :warning, count: sessions[:stale_active].to_i)
        end
        if events[:errors_last_24h].to_i.positive?
          warnings << warning(:recent_operational_errors, :warning, count: events[:errors_last_24h].to_i)
        end
        if configuration[:completed_session_retention_days].to_i <= 0
          warnings << warning(:retention_disabled, :info)
        end
        warnings
      end

      def overall_summary(configuration, warnings)
        return { state: "inactive", severity: "info" } unless configuration[:plugin_enabled]
        return { state: "critical", severity: "critical" } if warnings.any? { |item| item[:severity] == "critical" }
        return { state: "attention", severity: "warning" } if warnings.any? { |item| item[:severity] == "warning" }

        { state: "healthy", severity: "ok" }
      end

      def warning(code, severity, values = {})
        { code: code.to_s, severity: severity.to_s, values: values }
      end

      def heartrate_plugin_available?
        defined?(::LiveMetrics::CurrentStateStore) && defined?(::LiveMetrics::ProviderAccount)
      end

      def site_setting_value(name)
        return false unless SiteSetting.respond_to?(name)

        ActiveModel::Type::Boolean.new.cast(SiteSetting.public_send(name))
      rescue
        false
      end

      def setting_list(value)
        return value.map { |item| item.to_s.strip }.reject(&:blank?) if value.is_a?(Array)

        value.to_s.split(/[|,\n]/).map(&:strip).reject(&:blank?)
      end

      def table_exists?(name)
        ActiveRecord::Base.connection.data_source_exists?(name)
      rescue
        false
      end

      def column_exists?(table, column)
        ActiveRecord::Base.connection.column_exists?(table, column)
      rescue
        false
      end

      def safe_count(model)
        model.table_exists? ? model.count : 0
      rescue
        0
      end
    end
  end
end
