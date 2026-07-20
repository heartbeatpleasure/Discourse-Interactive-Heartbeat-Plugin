# frozen_string_literal: true

module ::InteractiveHeartbeat
  class ApiController < ::ApplicationController
    requires_plugin ::InteractiveHeartbeat::PLUGIN_NAME

    USER_SEARCH_LIMIT = 10
    SESSION_LIST_LIMIT = 30
    MAX_OPEN_SESSIONS_PER_USER = 5

    before_action :ensure_enabled
    before_action :ensure_logged_in
    before_action :ensure_allowed
    before_action :enforce_request_rate_limit

    class << self
      def allowed_user?(user)
        return false if user.blank? || !user.active? || user.staged?
        return true if user.staff?

        groups = list_setting(SiteSetting.interactive_heartbeat_allowed_groups)
        return true if groups.blank?

        normalized = groups.map(&:downcase)
        user.groups.where("lower(name) IN (?)", normalized).exists?
      rescue => e
        Rails.logger.warn(
          "[interactive_heartbeat] allowed_user_check_failed " \
          "user_id=#{user&.id} error=#{e.class}",
        )
        false
      end

      def list_setting(value)
        return value.map { |item| item.to_s.strip }.reject(&:blank?) if value.is_a?(Array)

        value.to_s.split(/[|,\n]/).map(&:strip).reject(&:blank?)
      end
    end

    # Avoid ActionController#config name collisions while retaining the public /config URL.
    def plugin_config
      account = active_heartrate_account(current_user)
      live = account.present? ? current_heartrate_state(account) : nil

      render_json(
        enabled: true,
        lovense_configured: ::InteractiveHeartbeat::LovenseClient.configured?,
        heartrate_plugin_available: heartrate_plugin_available?,
        heartrate_runtime_ready: heartrate_runtime_ready?,
        current_user: user_payload(current_user),
        heartrate: {
          connected: account&.connected? || false,
          provider: account&.provider,
          live: heartrate_runtime_ready? && ::LiveMetrics::CurrentStateStore.state_with_reading?(live),
        },
        defaults: {
          pulse_strength: bounded_integer(
            SiteSetting.interactive_heartbeat_default_pulse_strength,
            1,
            20,
            12,
          ),
          max_intensity: bounded_integer(
            SiteSetting.interactive_heartbeat_default_pulse_strength,
            1,
            20,
            12,
          ),
          pulse_duration_ms: bounded_integer(
            SiteSetting.interactive_heartbeat_default_pulse_duration_ms,
            100,
            500,
            180,
          ),
          signal_poll_ms: bounded_integer(
            SiteSetting.interactive_heartbeat_signal_poll_ms,
            500,
            5000,
            1000,
          ),
          signal_unstable_seconds: signal_unstable_seconds,
          signal_lost_seconds: signal_lost_seconds,
        },
      )
    end

    def users
      query = params[:q].to_s.strip
      return render_json(users: []) if query.length < 2

      escaped = ActiveRecord::Base.sanitize_sql_like(query.downcase)
      candidates = ::User
        .where(active: true, staged: false)
        .where.not(id: current_user.id)
        .where(
          "username_lower LIKE :query OR LOWER(COALESCE(name, '')) LIKE :query",
          query: "%#{escaped}%",
        )
        .order(:username_lower)
        .limit(USER_SEARCH_LIMIT * 3)
        .to_a
        .select { |user| self.class.allowed_user?(user) }
        .first(USER_SEARCH_LIMIT)

      render_json(users: candidates.map { |user| user_payload(user) })
    end

    def sessions
      ensure_database_ready!
      return if performed?

      rows = participant_sessions
        .includes(:initiator, :invitee, participants: :user)
        .order(updated_at: :desc)
        .limit(SESSION_LIST_LIMIT)
        .to_a

      rows.each(&:refresh_expiration!)
      render_json(sessions: rows.map { |session| session_payload(session.reload) })
    end

    def create_session
      ensure_database_ready!
      return if performed?

      target = ::User.find_by(username_lower: params[:username].to_s.downcase.strip)
      return render_error("user_not_found", status: 404, message: "The selected member could not be found.") if target.blank?
      return render_error("invalid_participant", status: 422, message: "You cannot invite yourself.") if target.id == current_user.id
      return render_error("participant_not_allowed", status: 403, message: "This member cannot use Interactive Heartbeat.") unless self.class.allowed_user?(target)

      directions = normalized_directions(params[:directions])
      return render_error("invalid_directions", status: 422, message: "Select at least one heartbeat direction.") if directions.blank?

      if open_session_count(current_user.id) >= MAX_OPEN_SESSIONS_PER_USER
        return render_error(
          "too_many_open_sessions",
          status: 422,
          message: "End or decline an existing session before creating another one.",
        )
      end

      existing = open_pair_session(current_user.id, target.id)
      if existing.present?
        existing.refresh_expiration!
        return render_json(session_payload(existing.reload), status: 200) unless existing.terminal?
      end

      session = nil
      ::InteractiveHeartbeat::Session.transaction do
        session = ::InteractiveHeartbeat::Session.create!(
          initiator_id: current_user.id,
          invitee_id: target.id,
          status: ::InteractiveHeartbeat::Session::STATUS_INVITED,
          mode: ::InteractiveHeartbeat::Session::MODE_HEARTBEAT_PULSE,
          settings: {
            "directions" => directions,
            "show_exact_bpm" => false,
          },
          expires_at: SiteSetting.interactive_heartbeat_invite_expiry_minutes.to_i.minutes.from_now,
        )

        session.participants.create!(
          user_id: current_user.id,
          role: ::InteractiveHeartbeat::Participant::ROLE_INITIATOR,
          accepted_at: Time.zone.now,
          presence_at: Time.zone.now,
          settings: default_participant_settings,
        )
        session.participants.create!(
          user_id: target.id,
          role: ::InteractiveHeartbeat::Participant::ROLE_INVITEE,
          settings: default_participant_settings,
        )
      end

      render_json(session_payload(session.reload), status: 201)
    rescue ActiveRecord::RecordInvalid => e
      render_error(
        "session_invalid",
        status: 422,
        message: e.record.errors.full_messages.join(", ").presence || "The session could not be created.",
      )
    end

    def show_session
      session = participant_session!
      return if performed?

      session.refresh_expiration!
      touch_presence!(session)
      render_json(session_payload(session.reload))
    end

    def accept_session
      session = participant_session!
      return if performed?

      participant = session.participant_for(current_user)
      return render_error("session_closed", status: 422, message: "This invitation is no longer open.") if session.expired? || session.terminal?

      session.accept!(participant)
      touch_presence!(session)
      render_json(session_payload(session.reload))
    end

    def decline_session
      session = participant_session!
      return if performed?

      participant = session.participant_for(current_user)
      session.decline!(participant)
      render_json(session_payload(session.reload))
    end

    def update_participant
      session = participant_session!
      return if performed?

      participant = session.participant_for(current_user)
      return render_error("accept_required", status: 422, message: "Accept the session before changing its setup.") unless participant.accepted?
      return render_error("session_closed", status: 422, message: "This session has ended.") if session.terminal?

      participant.update_preferences!(
        heartbeat_consent: boolean_param(:heartbeat_consent),
        toy_consent: boolean_param(:toy_consent),
        ready: boolean_param(:ready),
        settings: participant_settings_params,
      )
      touch_presence!(session)
      render_json(session_payload(session.reload))
    rescue ActiveRecord::RecordInvalid => e
      render_error(
        "participant_invalid",
        status: 422,
        message: e.record.errors.full_messages.join(", ").presence || "Your session settings could not be saved.",
      )
    end

    def start_session
      session = participant_session!
      return if performed?

      touch_presence!(session)
      session.reload
      unless required_heartbeat_sources_ready?(session)
        return render_error(
          "heartbeat_not_ready",
          status: 422,
          message: "Every heartbeat source in this session needs a fresh live reading before starting.",
        )
      end
      session.start!
      render_json(session_payload(session.reload))
    rescue ActiveRecord::RecordInvalid
      render_error(
        "session_not_ready",
        status: 422,
        message: "Both participants must be present, accepted, consented and ready before starting.",
      )
    end

    def pause_session
      session = participant_session!
      return if performed?

      session.pause!
      render_json(session_payload(session.reload))
    end

    def end_session
      session = participant_session!
      return if performed?

      session.end!
      render_json(session_payload(session.reload))
    end

    def presence
      session = participant_session!
      return if performed?

      touch_presence!(session)
      session.reload.refresh_presence_state!
      render_json(
        status: session.reload.status,
        participants: session.participants.reload.map { |participant| presence_payload(participant) },
      )
    end

    def signal
      session = participant_session!
      return if performed?

      participant = session.participant_for(current_user)
      touch_presence!(session)
      render_json(::InteractiveHeartbeat::HeartSignal.for(session: session.reload, target_participant: participant.reload))
    end

    def lovense_token
      session = participant_session_from_body!
      return if performed?

      participant = session.participant_for(current_user)
      return render_error("accept_required", status: 422, message: "Accept the session before connecting Lovense.") unless participant&.accepted?
      return render_error("session_closed", status: 422, message: "This session has ended.") if session.terminal?
      unless toy_target_required?(session, participant)
        return render_error(
          "lovense_not_required",
          status: 422,
          message: "This session direction does not use your toy.",
        )
      end

      render_json(::InteractiveHeartbeat::LovenseClient.authorization_payload(current_user))
    rescue ::InteractiveHeartbeat::LovenseClient::ConfigurationError => e
      render_error("lovense_not_configured", status: 503, message: e.message)
    rescue ::InteractiveHeartbeat::LovenseClient::ProviderError => e
      render_error("lovense_unavailable", status: 502, message: e.message)
    end

    private

    def ensure_enabled
      raise Discourse::NotFound unless SiteSetting.interactive_heartbeat_enabled
    end

    def ensure_allowed
      raise Discourse::InvalidAccess unless self.class.allowed_user?(current_user)
    end

    def enforce_request_rate_limit
      ::InteractiveHeartbeat::RequestRateLimiter.perform!(action_name, current_user)
    rescue ::InteractiveHeartbeat::RequestRateLimiter::LimitExceeded
      render_error("rate_limited", status: 429, message: "Too many requests. Please try again shortly.")
    end

    def participant_sessions
      ::InteractiveHeartbeat::Session
        .joins(:participants)
        .where(interactive_heartbeat_participants: { user_id: current_user.id })
        .distinct
    end

    def participant_session!
      ensure_database_ready!
      return nil if performed?

      session = participant_sessions
        .includes(:initiator, :invitee, participants: :user)
        .find_by(token: params[:token].to_s)
      return session if session.present?

      render_error("session_not_found", status: 404, message: "This private session could not be found.")
      nil
    end

    def participant_session_from_body!
      ensure_database_ready!
      return nil if performed?

      token = params[:session_token].to_s
      session = participant_sessions
        .includes(:initiator, :invitee, participants: :user)
        .find_by(token: token)
      return session if session.present?

      render_error("session_not_found", status: 404, message: "This private session could not be found.")
      nil
    end

    def touch_presence!(session)
      participant = session.participant_for(current_user)
      participant&.update_columns(presence_at: Time.zone.now, updated_at: Time.zone.now)
    end

    def session_payload(session)
      session.participants.load
      current_participant = session.participant_for(current_user)
      other_participant = session.other_participant(current_user)

      {
        token: session.token,
        status: session.status,
        mode: session.mode,
        directions: session.directions,
        expires_at: session.expires_at&.iso8601,
        started_at: session.started_at&.iso8601,
        ended_at: session.ended_at&.iso8601,
        can_start: session.startable? && required_heartbeat_sources_ready?(session),
        current_user: participant_payload(current_participant, session),
        other_user: participant_payload(other_participant, session),
        initiator: user_payload(session.initiator),
        invitee: user_payload(session.invitee),
        invite_url: "#{Discourse.base_url}/interactive-heartbeat/sessions/#{session.token}",
      }
    end

    def participant_payload(participant, session)
      return nil if participant.blank?

      {
        role: participant.role,
        user: user_payload(participant.user),
        accepted: participant.accepted?,
        declined: participant.declined_at.present?,
        heartbeat_consent: participant.heartbeat_consent?,
        toy_consent: participant.toy_consent?,
        ready: participant.ready?,
        present: participant.present_now?,
        settings: {
          max_intensity: participant.max_intensity,
          pulse_strength: participant.pulse_strength,
          pulse_duration_ms: participant.pulse_duration_ms,
        },
        needs_heartbeat_consent: heartbeat_source_required?(session, participant),
        needs_toy_consent: toy_target_required?(session, participant),
        heartbeat_ready: heartbeat_source_required?(session, participant) ? heartbeat_ready_for?(participant.user_id) : nil,
      }
    end

    def presence_payload(participant)
      {
        user_id: participant.user_id,
        present: participant.present_now?,
        ready: participant.ready?,
      }
    end

    def heartbeat_source_required?(session, participant)
      (participant.role == ::InteractiveHeartbeat::Participant::ROLE_INITIATOR &&
        session.directions.include?(::InteractiveHeartbeat::Session::DIRECTION_INITIATOR_TO_INVITEE)) ||
        (participant.role == ::InteractiveHeartbeat::Participant::ROLE_INVITEE &&
          session.directions.include?(::InteractiveHeartbeat::Session::DIRECTION_INVITEE_TO_INITIATOR))
    end

    def toy_target_required?(session, participant)
      (participant.role == ::InteractiveHeartbeat::Participant::ROLE_INVITEE &&
        session.directions.include?(::InteractiveHeartbeat::Session::DIRECTION_INITIATOR_TO_INVITEE)) ||
        (participant.role == ::InteractiveHeartbeat::Participant::ROLE_INITIATOR &&
          session.directions.include?(::InteractiveHeartbeat::Session::DIRECTION_INVITEE_TO_INITIATOR))
    end

    def user_payload(user)
      {
        id: user.id,
        username: user.username,
        name: user.name,
        avatar_template: user.avatar_template,
        profile_url: "/u/#{user.username}",
      }
    end

    def normalized_directions(value)
      Array(value).map(&:to_s).select { |direction| ::InteractiveHeartbeat::Session::DIRECTIONS.include?(direction) }.uniq
    end

    def default_participant_settings
      {
        "max_intensity" => bounded_integer(
          SiteSetting.interactive_heartbeat_default_pulse_strength,
          1,
          20,
          12,
        ),
        "pulse_strength" => bounded_integer(
          SiteSetting.interactive_heartbeat_default_pulse_strength,
          1,
          20,
          12,
        ),
        "pulse_duration_ms" => bounded_integer(
          SiteSetting.interactive_heartbeat_default_pulse_duration_ms,
          100,
          500,
          180,
        ),
      }
    end

    def participant_settings_params
      value = params[:settings]
      value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
      value.is_a?(Hash) ? value : {}
    end

    def boolean_param(key)
      ActiveModel::Type::Boolean.new.cast(params[key])
    end

    def open_session_count(user_id)
      ::InteractiveHeartbeat::Session.open
        .where("initiator_id = :id OR invitee_id = :id", id: user_id)
        .count
    end

    def open_pair_session(first_user_id, second_user_id)
      ::InteractiveHeartbeat::Session.open
        .where(
          "(initiator_id = :first AND invitee_id = :second) OR " \
          "(initiator_id = :second AND invitee_id = :first)",
          first: first_user_id,
          second: second_user_id,
        )
        .includes(:initiator, :invitee, participants: :user)
        .order(updated_at: :desc)
        .first
    end

    def required_heartbeat_sources_ready?(session)
      return false unless heartrate_runtime_ready?

      session.participants.all? do |participant|
        !heartbeat_source_required?(session, participant) || heartbeat_ready_for?(participant.user_id)
      end
    end

    def heartbeat_ready_for?(user_id)
      account = active_heartrate_account(::User.find_by(id: user_id))
      return false if account.blank? || !account.connected?

      state = current_heartrate_state(account)
      return false unless ::LiveMetrics::CurrentStateStore.state_with_reading?(state)
      return false unless state[:heart_rate].to_i.between?(30, 220)

      state[:age_seconds].to_i < signal_lost_seconds
    rescue
      false
    end

    def active_heartrate_account(user)
      return nil unless heartrate_plugin_available?
      return nil if user.blank?

      ::LiveMetrics::ProviderAccount.enabled_providers.active.find_by(user_id: user.id)
    rescue ActiveRecord::StatementInvalid
      nil
    end

    def current_heartrate_state(account)
      return nil unless heartrate_runtime_ready?

      ::LiveMetrics::CurrentStateStore.read(account)
    end

    def heartrate_plugin_available?
      defined?(::LiveMetrics::ProviderAccount) && defined?(::LiveMetrics::CurrentStateStore)
    end

    def heartrate_runtime_ready?
      heartrate_plugin_available? &&
        defined?(::LiveMetrics::RefreshCoordinator) &&
        ::LiveMetrics::RefreshCoordinator.async_enabled?
    rescue
      false
    end

    def signal_unstable_seconds
      unstable = bounded_integer(
        SiteSetting.interactive_heartbeat_signal_unstable_seconds,
        2,
        20,
        5,
      )
      [unstable, signal_lost_seconds - 1].min
    end

    def signal_lost_seconds
      bounded_integer(
        SiteSetting.interactive_heartbeat_signal_stale_seconds,
        6,
        60,
        12,
      )
    end

    def ensure_database_ready!
      ready = ::InteractiveHeartbeat::Session.table_exists? && ::InteractiveHeartbeat::Participant.table_exists?
      return if ready

      render_error(
        "database_not_ready",
        status: 503,
        message: "Interactive Heartbeat is still being prepared. Run migrations and rebuild/restart Discourse.",
      )
    rescue ActiveRecord::StatementInvalid
      render_error(
        "database_not_ready",
        status: 503,
        message: "Interactive Heartbeat is still being prepared. Run migrations and rebuild/restart Discourse.",
      )
    end

    def bounded_integer(value, minimum, maximum, fallback)
      parsed = Integer(value, exception: false)
      return fallback unless parsed

      [[parsed, minimum].max, maximum].min
    end

    def render_json(payload = nil, status: 200, **attributes)
      body = payload || {}
      body = body.merge(attributes) unless attributes.empty?
      render json: body, status: status
    end

    def render_error(key, status:, message:)
      render_json({ error: key, message: message }, status: status)
    end
  end
end
