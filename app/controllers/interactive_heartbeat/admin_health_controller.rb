# frozen_string_literal: true

module ::InteractiveHeartbeat
  class AdminHealthController < ::Admin::AdminController
    requires_plugin ::InteractiveHeartbeat::PLUGIN_NAME

    def index
      response.headers["Cache-Control"] = "no-store"
      render_json_dump(::InteractiveHeartbeat::AdminHealth.summary)
    end
  end
end
