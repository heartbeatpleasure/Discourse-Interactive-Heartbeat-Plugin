# frozen_string_literal: true

module ::InteractiveHeartbeat
  class ApiController < ::ApplicationController
    requires_plugin ::InteractiveHeartbeat::PLUGIN_NAME

    USER_SEARCH_LIMIT = 10
    DEFAULT_COMPLETED_SESSION_LIMIT = 5
    MAX_OPEN_SESSIONS_PER_USER = 5

    before_action :ensure_enabled
    before_action :ensure_logged_in
    before_action :ensure_allowed
    before_action :ensure_test_lab_admin, only: %i[test_lab_signal test_lab_lovense_token]
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
        defaults: default_participant_settings.merge(
          "signal_poll_ms" => bounded_integer(
            SiteSetting.interactive_heartbeat_signal_poll_ms,
            500,
            5000,
            1000,
          ),
          "signal_unstable_seconds" => signal_unstable_seconds,
          "signal_lost_seconds" => signal_lost_seconds,
        ),
        session_modes: ::InteractiveHeartbeat::Session::PUBLIC_MODES,
        response_modes: ::InteractiveHeartbeat::Participant::RESPONSE_MODES,
        test_lab_enabled: SiteSetting.interactive_heartbeat_test_lab_enabled && current_user.admin?,
        test_lab_url: "/interactive-heartbeat/test-lab",
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

      participant_sessions
        .where(status: ::InteractiveHeartbeat::Session::STATUS_INVITED)
        .where("expires_at <= ?", Time.zone.now)
        .find_each(&:refresh_expiration!)

      base = visible_participant_sessions.includes(:initiator, :invitee, participants: :user)
      open_rows = base
        .where(status: ::InteractiveHeartbeat::Session::OPEN_STATUSES)
        .order(Arel.sql("interactive_heartbeat_sessions.updated_at DESC"))
        .to_a

      completed_scope = base
        .where(status: ::InteractiveHeartbeat::Session::TERMINAL_STATUSES)
        .order(
          Arel.sql(
            "COALESCE(interactive_heartbeat_sessions.ended_at, interactive_heartbeat_sessions.updated_at) DESC",
          ),
        )
      completed_total = completed_scope.except(:order).count
      history_expanded = ActiveModel::Type::Boolean.new.cast(params[:history_all])
      completed_rows = if history_expanded
        completed_scope.to_a
      else
        completed_scope.limit(DEFAULT_COMPLETED_SESSION_LIMIT).to_a
      end

      render_json(
        sessions: (open_rows + completed_rows).map { |session| session_payload(session) },
        history: {
          total: completed_total,
          shown: completed_rows.length,
          expanded: history_expanded,
          has_more: completed_total > completed_rows.length,
          default_limit: DEFAULT_COMPLETED_SESSION_LIMIT,
        },
      )
    end

    def clear_completed_sessions
      ensure_database_ready!
      return if performed?

      terminal_sessions = participant_sessions
        .where(status: ::InteractiveHeartbeat::Session::TERMINAL_STATUSES)
        .select(:id, :token)
        .to_a
      session_ids = terminal_sessions.map(&:id)
      session_tokens = terminal_sessions.map(&:token)

      cleared = if session_ids.present?
        ::InteractiveHeartbeat::Participant
          .where(user_id: current_user.id, session_id: session_ids, dismissed_at: nil)
          .update_all(dismissed_at: Time.zone.now, updated_at: Time.zone.now)
      else
        0
      end

      ::InteractiveHeartbeat::SessionNotifier.clear_for!(
        user: current_user,
        session_tokens: session_tokens,
      )

      render_json(cleared: cleared)
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
          mode: ::InteractiveHeartbeat::Session::MODE_CROSS_HEARTBEAT,
          settings: {
            "directions" => directions,
            "show_exact_bpm" => false,
            "configuration_revision" => 1,
            "configuration_proposed_by_id" => current_user.id,
          },
          expires_at: SiteSetting.interactive_heartbeat_invite_expiry_minutes.to_i.minutes.from_now,
        )

        initiator_participant = session.participants.create!(
          user_id: current_user.id,
          role: ::InteractiveHeartbeat::Participant::ROLE_INITIATOR,
          accepted_at: Time.zone.now,
          presence_at: Time.zone.now,
          settings: default_participant_settings.merge("accepted_configuration_revision" => 1),
        )
        initiator_participant.grant_session_permissions!
        session.participants.create!(
          user_id: target.id,
          role: ::InteractiveHeartbeat::Participant::ROLE_INVITEE,
          settings: default_participant_settings.merge("configuration_consent_revoked" => true),
        )
      end

      ::InteractiveHeartbeat::SessionNotifier.notify!(
        session: session,
        recipient: target,
        actor: current_user,
        event: "invitation",
      )

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

      was_accepted = participant.accepted?
      session.accept!(participant)
      touch_presence!(session)
      notify_other_participant!(session, "invitation_accepted") unless was_accepted
      render_json(session_payload(session.reload))
    end

    def join_session
      session = participant_session!
      return if performed?

      participant = session.participant_for(current_user)
      return render_error("session_closed", status: 422, message: "This invitation is no longer open.") if session.expired? || session.terminal?

      was_accepted = participant.accepted?
      ::InteractiveHeartbeat::Session.transaction do
        session.accept!(participant) unless participant.accepted?
        participant.reload.grant_session_permissions!(settings: participant_settings_params)
      end
      touch_presence!(session)
      notify_other_participant!(session, "invitation_accepted") unless was_accepted
      render_json(session_payload(session.reload))
    rescue ActiveRecord::RecordInvalid => e
      render_error(
        "participant_invalid",
        status: 422,
        message: e.record.errors.full_messages.join(", ").presence || "The session could not be joined.",
      )
    end

    def grant_permissions
      session = participant_session!
      return if performed?

      participant = session.participant_for(current_user)
      return render_error("accept_required", status: 422, message: "Join the session before allowing it.") unless participant&.accepted?
      return render_error("session_closed", status: 422, message: "This session has ended.") if session.terminal?

      previously_accepted_configuration = participant.configuration_accepted?
      participant.grant_session_permissions!(settings: participant_settings_params)
      touch_presence!(session)
      if !previously_accepted_configuration && participant.reload.configuration_accepted?
        notify_other_participant!(
          session.reload,
          "mode_accepted",
          revision: session.configuration_revision,
        )
      end
      render_json(session_payload(session.reload))
    rescue ActiveRecord::RecordInvalid => e
      render_error(
        "participant_invalid",
        status: 422,
        message: e.record.errors.full_messages.join(", ").presence || "Your session permissions could not be saved.",
      )
    end

    def revoke_permissions
      session = participant_session!
      return if performed?

      participant = session.participant_for(current_user)
      return render_error("accept_required", status: 422, message: "Join the session before changing permissions.") unless participant&.accepted?
      return render_error("session_closed", status: 422, message: "This session has ended.") if session.terminal?

      participant.revoke_session_permissions!
      touch_presence!(session)
      render_json(session_payload(session.reload))
    end

    def decline_session
      session = participant_session!
      return if performed?

      participant = session.participant_for(current_user)
      session.decline!(participant)
      notify_other_participant!(session.reload, "session_declined")
      render_json(session_payload(session.reload))
    end

    def update_participant
      session = participant_session!
      return if performed?

      participant = session.participant_for(current_user)
      return render_error("accept_required", status: 422, message: "Accept the session before changing its setup.") unless participant.accepted?
      return render_error("session_closed", status: 422, message: "This session has ended.") if session.terminal?

      was_ready = participant.ready?
      participant.update_preferences!(
        heartbeat_consent: boolean_param(:heartbeat_consent),
        toy_consent: boolean_param(:toy_consent),
        configuration_consent: optional_boolean_param(:configuration_consent),
        ready: boolean_param(:ready),
        settings: participant_settings_params,
      )
      touch_presence!(session)
      session.reload
      if !was_ready && participant.reload.ready? && session.all_ready?
        notify_other_participant!(session, "both_ready")
      end
      render_json(session_payload(session))
    rescue ActiveRecord::RecordInvalid => e
      render_error(
        "participant_invalid",
        status: 422,
        message: e.record.errors.full_messages.join(", ").presence || "Your session settings could not be saved.",
      )
    end

    def update_configuration
      session = participant_session!
      return if performed?

      participant = session.participant_for(current_user)
      return render_error("accept_required", status: 422, message: "Accept the session before changing its mode.") unless participant&.accepted?
      return render_error("session_closed", status: 422, message: "This session has ended.") if session.terminal?

      previously_accepted_configuration = participant.configuration_accepted?
      changed = session.propose_configuration!(
        participant: participant,
        requested_mode: params[:mode],
        requested_leader_user_id: params[:leader_user_id],
      )
      touch_presence!(session)
      session.reload
      if changed
        notify_other_participant!(
          session,
          "mode_approval",
          revision: session.configuration_revision,
        )
      elsif !previously_accepted_configuration && participant.reload.configuration_accepted?
        notify_other_participant!(
          session,
          "mode_accepted",
          revision: session.configuration_revision,
        )
      end
      render_json(session_payload(session))
    rescue ActiveRecord::RecordInvalid => e
      render_error(
        "configuration_invalid",
        status: 422,
        message: e.record.errors.full_messages.join(", ").presence || "The session mode could not be changed.",
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
        message: "Both participants must accept the session mode, be present, consented and ready before starting.",
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
      notify_other_participant!(session.reload, "session_ended")
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

    def test_lab_signal
      render_json(
        ::InteractiveHeartbeat::TestLabSignal.for(
          user: current_user,
          parameters: test_lab_signal_params,
        ),
      )
    end

    def test_lab_lovense_token
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

    def ensure_test_lab_admin
      raise Discourse::NotFound unless SiteSetting.interactive_heartbeat_test_lab_enabled
      raise Discourse::NotFound unless current_user&.admin?
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

    def visible_participant_sessions
      participant_sessions.where(interactive_heartbeat_participants: { dismissed_at: nil })
    end

    def notify_other_participant!(session, event, revision: nil)
      recipient = session.other_participant(current_user)&.user
      return if recipient.blank?

      ::InteractiveHeartbeat::SessionNotifier.notify!(
        session: session,
        recipient: recipient,
        actor: current_user,
        event: event,
        revision: revision,
      )
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
        mode: session.mode_key,
        directions: session.directions,
        configuration: {
          revision: session.configuration_revision,
          proposed_by_id: session.configuration_proposed_by_id,
          leader_user_id: session.leader_user_id,
          leader: session.leader.present? ? user_payload(session.leader) : nil,
          current_user_accepted: session.configuration_accepted_by?(current_participant),
          other_user_accepted: session.configuration_accepted_by?(other_participant),
        },
        created_at: session.created_at&.iso8601,
        updated_at: session.updated_at&.iso8601,
        expires_at: session.expires_at&.iso8601,
        started_at: session.started_at&.iso8601,
        ended_at: session.ended_at&.iso8601,
        activity_at: session_activity_at(session)&.iso8601,
        terminal: session.terminal?,
        can_open: !session.terminal?,
        can_copy_invite: session.status == ::InteractiveHeartbeat::Session::STATUS_INVITED &&
          current_participant&.role == ::InteractiveHeartbeat::Participant::ROLE_INITIATOR,
        can_start: session.startable? && required_heartbeat_sources_ready?(session),
        current_user: participant_payload(current_participant, session),
        other_user: participant_payload(other_participant, session),
        initiator: user_payload(session.initiator),
        invitee: user_payload(session.invitee),
        invite_url: "#{Discourse.base_url}/interactive-heartbeat/sessions/#{session.token}",
      }
    end

    def session_activity_at(session)
      if session.terminal?
        session.ended_at || session.updated_at
      elsif session.status == ::InteractiveHeartbeat::Session::STATUS_ACTIVE
        session.started_at || session.updated_at
      elsif session.status == ::InteractiveHeartbeat::Session::STATUS_INVITED
        session.created_at
      else
        session.updated_at
      end
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
        configuration_accepted: participant.configuration_accepted?,
        permissions_granted: participant.session_permissions_granted?,
        permission_scope: participant.session_permission_scope? ? "session" : "granular",
        missing_permissions: participant.missing_session_permissions,
        settings: participant.response_settings_payload,
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
      session.heartbeat_required_for?(participant.user_id)
    end

    def toy_target_required?(session, participant)
      session.toy_required_for?(participant.user_id)
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
      maximum = bounded_integer(
        SiteSetting.interactive_heartbeat_default_pulse_strength,
        1,
        20,
        12,
      )
      {
        "response_mode" => ::InteractiveHeartbeat::Participant::RESPONSE_FIXED,
        "max_intensity" => maximum,
        "min_intensity" => [3, maximum].min,
        "pulse_strength" => maximum,
        "pulse_duration_ms" => bounded_integer(
          SiteSetting.interactive_heartbeat_default_pulse_duration_ms,
          100,
          500,
          180,
        ),
        "zone_low_max_bpm" => 79,
        "zone_medium_max_bpm" => 99,
        "zone_high_max_bpm" => 119,
        "zone_low_intensity" => [3, maximum].min,
        "zone_medium_intensity" => [8, maximum].min,
        "zone_high_intensity" => [11, maximum].min,
        "zone_peak_intensity" => maximum,
        "smooth_min_bpm" => 70,
        "smooth_max_bpm" => 130,
        "baseline_bpm" => 70,
        "relative_range_bpm" => 50,
        "ramp_up_per_second" => 2,
        "ramp_down_per_second" => 4,
        "hysteresis_bpm" => 3,
      }
    end

    def test_lab_signal_params
      value = params[:test_lab]
      value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
      value.is_a?(Hash) ? value : {}
    end

    def participant_settings_params
      value = params[:settings]
      value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
      value.is_a?(Hash) ? value : {}
    end

    def boolean_param(key)
      ActiveModel::Type::Boolean.new.cast(params[key])
    end

    def optional_boolean_param(key)
      return nil unless params.key?(key)

      boolean_param(key)
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

      session.required_heartbeat_user_ids.all? { |user_id| heartbeat_ready_for?(user_id) }
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
      ready =
        ::InteractiveHeartbeat::Session.table_exists? &&
          ::InteractiveHeartbeat::Participant.table_exists? &&
          ::InteractiveHeartbeat::Participant.column_names.include?("dismissed_at")
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
