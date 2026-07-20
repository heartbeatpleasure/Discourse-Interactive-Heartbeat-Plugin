# frozen_string_literal: true

require "net/http"
require "json"
require "openssl"

module ::InteractiveHeartbeat
  class LovenseClient
    TOKEN_URL = URI("https://api.lovense-api.com/api/basicApi/getToken")
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10

    class ConfigurationError < StandardError
    end

    class ProviderError < StandardError
    end

    class << self
      def configured?
        SiteSetting.interactive_heartbeat_lovense_developer_token.present? &&
          SiteSetting.interactive_heartbeat_lovense_platform_name.present?
      end

      def authorization_payload(user)
        raise ConfigurationError, "Lovense is not configured." unless configured?

        response = request_token(user)
        auth_token = response.dig("data", "authToken").to_s
        raise ProviderError, response["message"].presence || "Lovense did not return an authorization token." if auth_token.blank?

        {
          auth_token: auth_token,
          uid: user.id.to_s,
          platform: SiteSetting.interactive_heartbeat_lovense_platform_name.to_s,
          app_type: normalized_app_type,
          sdk_url: ::InteractiveHeartbeat::SDK_URL,
        }
      end

      def verified_callback_user(uid:, utoken:)
        user_id = Integer(uid, exception: false)
        provided_token = utoken.to_s
        return nil unless user_id&.positive? && provided_token.present?

        user = ::User.find_by(id: user_id, active: true, staged: false)
        return nil if user.blank?

        expected_token = user_verification_token(user)
        return nil unless expected_token.bytesize == provided_token.bytesize
        return nil unless ActiveSupport::SecurityUtils.secure_compare(expected_token, provided_token)

        user
      rescue ArgumentError, TypeError
        nil
      end

      private

      def request_token(user)
        request = Net::HTTP::Post.new(TOKEN_URL)
        request["Content-Type"] = "application/json"
        request["Accept"] = "application/json"
        request.body = JSON.generate(
          token: SiteSetting.interactive_heartbeat_lovense_developer_token,
          uid: user.id.to_s,
          uname: user.username.to_s,
          utoken: user_verification_token(user),
        )

        response = Net::HTTP.start(
          TOKEN_URL.host,
          TOKEN_URL.port,
          use_ssl: true,
          open_timeout: OPEN_TIMEOUT,
          read_timeout: READ_TIMEOUT,
        ) { |http| http.request(request) }

        unless response.is_a?(Net::HTTPSuccess)
          raise ProviderError, "Lovense authorization request failed."
        end

        parsed = JSON.parse(response.body.to_s)
        unless parsed["code"].to_i.zero?
          raise ProviderError, parsed["message"].presence || "Lovense rejected the authorization request."
        end

        parsed
      rescue JSON::ParserError, Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError => e
        Rails.logger.warn("[interactive_heartbeat] lovense_token_failed error=#{e.class}")
        raise ProviderError, "Lovense authorization is temporarily unavailable."
      end

      def user_verification_token(user)
        secret = Rails.application.secret_key_base.to_s
        OpenSSL::HMAC.hexdigest("SHA256", secret, "interactive-heartbeat:#{user.id}")
      end

      def normalized_app_type
        value = SiteSetting.interactive_heartbeat_lovense_app_type.to_s
        %w[remote connect].include?(value) ? value : "remote"
      end
    end
  end
end
