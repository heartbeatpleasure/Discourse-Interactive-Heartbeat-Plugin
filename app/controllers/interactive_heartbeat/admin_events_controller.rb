# frozen_string_literal: true

module ::InteractiveHeartbeat
  class AdminEventsController < ::Admin::AdminController
    requires_plugin ::InteractiveHeartbeat::PLUGIN_NAME

    def index
      response.headers["Cache-Control"] = "no-store"
      render_json_dump(
        events: ::InteractiveHeartbeat::AdminEventLog.recent(
          category: params[:category],
          severity: params[:severity],
          limit: params[:limit],
        ),
        generated_at: Time.zone.now.iso8601,
        total_events: ::InteractiveHeartbeat::AdminEventLog.total_count,
        retention_days: (::InteractiveHeartbeat::AdminEventLog::RETENTION_SECONDS / 1.day).to_i,
        max_events: ::InteractiveHeartbeat::AdminEventLog::MAX_EVENTS,
      )
    end
  end
end
