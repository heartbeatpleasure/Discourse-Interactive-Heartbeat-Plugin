# frozen_string_literal: true

module ::InteractiveHeartbeat
  class PageController < ::ApplicationController
    requires_plugin ::InteractiveHeartbeat::PLUGIN_NAME

    before_action :ensure_enabled
    before_action :ensure_logged_in
    before_action :ensure_allowed

    def index
      render layout: "application"
    end

    def test_lab
      raise Discourse::NotFound unless SiteSetting.interactive_heartbeat_test_lab_enabled
      raise Discourse::NotFound unless current_user&.admin?

      render layout: "application"
    end

    private

    def ensure_enabled
      raise Discourse::NotFound unless SiteSetting.interactive_heartbeat_enabled
    end

    def ensure_allowed
      raise Discourse::InvalidAccess unless ::InteractiveHeartbeat::ApiController.allowed_user?(current_user)
    end
  end
end
