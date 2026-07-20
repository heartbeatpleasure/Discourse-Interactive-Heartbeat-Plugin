# frozen_string_literal: true

module ::InteractiveHeartbeat
  class LovenseCallbackController < ::ApplicationController
    requires_plugin ::InteractiveHeartbeat::PLUGIN_NAME

    skip_before_action :check_xhr, raise: false
    skip_before_action :verify_authenticity_token, raise: false
    skip_before_action :redirect_to_login_if_required, raise: false

    before_action :ensure_enabled

    def create
      uid = params[:uid].to_s
      utoken = params[:utoken].to_s

      if uid.blank? || utoken.blank?
        log_rejected("missing_credentials", uid)
        return render_callback_error("invalid_callback", status: 422)
      end

      user = ::InteractiveHeartbeat::LovenseClient.verified_callback_user(
        uid: uid,
        utoken: utoken,
      )

      unless user.present? && ::InteractiveHeartbeat::ApiController.allowed_user?(user)
        log_rejected("verification_failed", uid)
        return render_callback_error("invalid_callback", status: 403)
      end

      state = ::InteractiveHeartbeat::LovenseCallbackStore.write(
        user: user,
        payload: callback_payload,
      )

      unless state.present?
        Rails.logger.warn(
          "[interactive_heartbeat] lovense_callback_store_unavailable " \
          "user_id=#{user.id}",
        )
        return render_callback_error("temporarily_unavailable", status: 503)
      end

      Rails.logger.info(
        "[interactive_heartbeat] lovense_callback_received " \
        "user_id=#{user.id} app_type=#{safe_log_value(state[:app_type])} " \
        "platform=#{safe_log_value(state[:platform])} " \
        "toy_count=#{state[:toy_count].to_i} " \
        "online_toy_count=#{state[:online_toy_count].to_i}",
      )

      render json: { result: true }, status: :ok
    rescue => e
      Rails.logger.error(
        "[interactive_heartbeat] lovense_callback_failed " \
        "error=#{e.class}",
      )
      render_callback_error("temporarily_unavailable", status: 500)
    end

    private

    def ensure_enabled
      raise Discourse::NotFound unless SiteSetting.interactive_heartbeat_enabled
    end

    def callback_payload
      params.to_unsafe_h.slice(
        "appVersion",
        "toys",
        "appType",
        "version",
        "platform",
      )
    end

    def render_callback_error(code, status:)
      render json: { result: false, code: code }, status: status
    end

    def log_rejected(reason, uid)
      parsed_uid = Integer(uid, exception: false)
      Rails.logger.warn(
        "[interactive_heartbeat] lovense_callback_rejected " \
        "reason=#{reason} user_id=#{parsed_uid&.positive? ? parsed_uid : "invalid"}",
      )
    end

    def safe_log_value(value)
      normalized = value.to_s.gsub(/[^a-zA-Z0-9._-]/, "")
      normalized.presence || "unknown"
    end
  end
end
