# frozen_string_literal: true

module ::InteractiveHeartbeat
  class LovenseCallbackController < ::ApplicationController
    requires_plugin ::InteractiveHeartbeat::PLUGIN_NAME

    skip_before_action :check_xhr, raise: false
    skip_before_action :verify_authenticity_token, raise: false
    skip_before_action :redirect_to_login_if_required, raise: false

    MAX_CALLBACK_BYTES = 64 * 1024
    CALLBACK_UID_PATTERN = /\A[1-9][0-9]{0,19}\z/
    CALLBACK_TOKEN_PATTERN = /\A[0-9a-f]{64}\z/i

    before_action :ensure_enabled
    before_action :enforce_callback_request_limits

    def create
      uid = params[:uid].to_s
      utoken = params[:utoken].to_s

      unless CALLBACK_UID_PATTERN.match?(uid) && CALLBACK_TOKEN_PATTERN.match?(utoken)
        log_rejected("invalid_credentials", uid)
        record_callback_event(result: :invalid, severity: :warning)
        return render_callback_error("invalid_callback", status: 422)
      end

      user = ::InteractiveHeartbeat::LovenseClient.verified_callback_user(
        uid: uid,
        utoken: utoken,
      )

      unless user.present? && ::InteractiveHeartbeat::ApiController.allowed_user?(user)
        log_rejected("verification_failed", uid)
        record_callback_event(result: :rejected, severity: :warning)
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
        record_callback_event(result: :temporarily_unavailable, severity: :error)
        return render_callback_error("temporarily_unavailable", status: 503)
      end

      Rails.logger.info(
        "[interactive_heartbeat] lovense_callback_received " \
        "user_id=#{user.id} app_type=#{safe_log_value(state[:app_type])} " \
        "platform=#{safe_log_value(state[:platform])} " \
        "toy_count=#{state[:toy_count].to_i} " \
        "online_toy_count=#{state[:online_toy_count].to_i}",
      )

      record_callback_event(result: :success)
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

    def enforce_callback_request_limits
      declared_bytes = request.content_length.to_i
      actual_bytes = request.raw_post.to_s.bytesize
      if declared_bytes > MAX_CALLBACK_BYTES || actual_bytes > MAX_CALLBACK_BYTES
        record_callback_event(result: :payload_too_large, severity: :warning)
        render_callback_error("payload_too_large", status: 413)
        return
      end

      ::InteractiveHeartbeat::RequestRateLimiter.perform_lovense_callback!(
        uid: params[:uid],
        ip: request.remote_ip,
      )
    rescue ::InteractiveHeartbeat::RequestRateLimiter::LimitExceeded
      record_callback_event(result: :rate_limited, severity: :warning)
      render_callback_error("rate_limited", status: 429)
    end

    def record_callback_event(result:, severity: :info)
      ::InteractiveHeartbeat::AdminEventLog.record(
        category: :lovense,
        event: :lovense_callback,
        result: result,
        severity: severity,
        client_context: :server,
      )
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
