# frozen_string_literal: true

# name: Discourse-Interactive-Heartbeat-Plugin
# about: Private, consent-based heartbeat sessions with Lovense toy control
# version: 0.4.0
# authors: Chris
# url: https://github.com/xxxxxx/Discourse-Interactive-Heartbeat-Plugin
# required_version: 3.3.0

enabled_site_setting :interactive_heartbeat_enabled

extend_content_security_policy(
  script_src: %w[https://api.lovense-api.com],
  connect_src: %w[
    https://api.lovense-api.com
    https://*.lovense-api.com
    wss://*.lovense-api.com
    https://*.lovense.club:*
    wss://*.lovense.club:*
  ],
  img_src: %w[https://*.lovense-api.com https://*.lovense.com],
)

module ::InteractiveHeartbeat
  PLUGIN_NAME = "Discourse-Interactive-Heartbeat-Plugin"
  SDK_URL = "https://api.lovense-api.com/basic-sdk/core.min.js"
end

after_initialize do
  Rails.application.config.filter_parameters |= %i[
    token
    authToken
    auth_token
    developer_token
    interactive_heartbeat_lovense_developer_token
    utoken
    toy_id
    toys
    domain
    httpPort
    wsPort
    httpsPort
    wssPort
  ]

  require_relative "lib/interactive_heartbeat/request_rate_limiter"
  require_relative "lib/interactive_heartbeat/lovense_client"
  require_relative "lib/interactive_heartbeat/lovense_callback_store"
  require_relative "lib/interactive_heartbeat/intensity_mapper"
  require_relative "lib/interactive_heartbeat/heart_signal"

  require_dependency File.expand_path(
    "app/models/interactive_heartbeat/session.rb",
    __dir__,
  )
  require_dependency File.expand_path(
    "app/models/interactive_heartbeat/participant.rb",
    __dir__,
  )
  require_dependency File.expand_path(
    "app/controllers/interactive_heartbeat/page_controller.rb",
    __dir__,
  )
  require_dependency File.expand_path(
    "app/controllers/interactive_heartbeat/api_controller.rb",
    __dir__,
  )
  require_dependency File.expand_path(
    "app/controllers/interactive_heartbeat/lovense_callback_controller.rb",
    __dir__,
  )

  add_model_callback(::User, :before_destroy) do
    ::InteractiveHeartbeat::Session.where(initiator_id: id).or(
      ::InteractiveHeartbeat::Session.where(invitee_id: id),
    ).find_each(&:end_for_user_cleanup!)
    ::InteractiveHeartbeat::LovenseCallbackStore.delete(id)
  rescue => e
    Rails.logger.warn(
      "[interactive_heartbeat] user_cleanup_failed user_id=#{id} " \
      "error=#{e.class}",
    )
  end

  Discourse::Application.routes.append do
    get "/interactive-heartbeat" => "interactive_heartbeat/page#index"
    get "/interactive-heartbeat/sessions/:token" => "interactive_heartbeat/page#index"

    get "/interactive-heartbeat/api/config" => "interactive_heartbeat/api#plugin_config",
        defaults: { format: :json }
    get "/interactive-heartbeat/api/users" => "interactive_heartbeat/api#users",
        defaults: { format: :json }
    get "/interactive-heartbeat/api/sessions" => "interactive_heartbeat/api#sessions",
        defaults: { format: :json }
    post "/interactive-heartbeat/api/sessions" => "interactive_heartbeat/api#create_session",
         defaults: { format: :json }
    get "/interactive-heartbeat/api/sessions/:token" => "interactive_heartbeat/api#show_session",
        defaults: { format: :json }
    put "/interactive-heartbeat/api/sessions/:token/accept" => "interactive_heartbeat/api#accept_session",
        defaults: { format: :json }
    put "/interactive-heartbeat/api/sessions/:token/decline" => "interactive_heartbeat/api#decline_session",
        defaults: { format: :json }
    put "/interactive-heartbeat/api/sessions/:token/participant" => "interactive_heartbeat/api#update_participant",
        defaults: { format: :json }
    put "/interactive-heartbeat/api/sessions/:token/configuration" => "interactive_heartbeat/api#update_configuration",
        defaults: { format: :json }
    put "/interactive-heartbeat/api/sessions/:token/start" => "interactive_heartbeat/api#start_session",
        defaults: { format: :json }
    put "/interactive-heartbeat/api/sessions/:token/pause" => "interactive_heartbeat/api#pause_session",
        defaults: { format: :json }
    put "/interactive-heartbeat/api/sessions/:token/end" => "interactive_heartbeat/api#end_session",
        defaults: { format: :json }
    put "/interactive-heartbeat/api/sessions/:token/presence" => "interactive_heartbeat/api#presence",
        defaults: { format: :json }
    get "/interactive-heartbeat/api/sessions/:token/signal" => "interactive_heartbeat/api#signal",
        defaults: { format: :json }
    post "/interactive-heartbeat/api/lovense/token" => "interactive_heartbeat/api#lovense_token",
         defaults: { format: :json }

    # Lovense Remote sends this callback without a Discourse login or CSRF token.
    # The callback controller authenticates the payload with the per-user utoken.
    post "/interactive-heartbeat/lovense/callback" =>
           "interactive_heartbeat/lovense_callback#create",
         defaults: { format: :json }
  end
end
