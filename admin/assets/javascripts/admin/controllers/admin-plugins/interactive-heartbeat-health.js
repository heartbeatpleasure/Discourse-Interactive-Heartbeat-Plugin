import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";
import { i18n } from "discourse-i18n";

function formatNumber(value) {
  const number = Number(value || 0);
  return Number.isFinite(number) ? new Intl.NumberFormat().format(number) : "0";
}

function formatDateTime(value) {
  if (!value) {
    return i18n("admin.interactive_heartbeat.health.not_available");
  }

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return i18n("admin.interactive_heartbeat.health.not_available");
  }

  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "medium",
  }).format(date);
}

function enabledLabel(value) {
  return value
    ? i18n("admin.interactive_heartbeat.health.enabled")
    : i18n("admin.interactive_heartbeat.health.disabled");
}

function yesNoLabel(value) {
  return value
    ? i18n("admin.interactive_heartbeat.health.yes")
    : i18n("admin.interactive_heartbeat.health.no");
}

function severityClass(severity) {
  switch (String(severity || "ok")) {
    case "critical":
      return "is-critical";
    case "warning":
      return "is-warning";
    case "info":
      return "is-info";
    default:
      return "is-ok";
  }
}

function extractError(error) {
  return (
    error?.jqXHR?.responseJSON?.errors?.[0] ||
    error?.responseJSON?.errors?.[0] ||
    error?.message ||
    i18n("admin.interactive_heartbeat.health.load_error")
  );
}

export default class AdminPluginsInteractiveHeartbeatHealthController extends Controller {
  @tracked data = null;
  @tracked isLoading = false;
  @tracked error = null;

  resetState() {
    this.data = null;
    this.isLoading = false;
    this.error = null;
  }

  @action
  async loadHealth() {
    if (this.isLoading) {
      return;
    }

    this.isLoading = true;
    this.error = null;
    try {
      this.data = await ajax("/admin/plugins/interactive-heartbeat/health.json");
    } catch (error) {
      this.error = extractError(error);
    } finally {
      this.isLoading = false;
    }
  }

  get hasData() {
    return Boolean(this.data);
  }

  get generatedAtLabel() {
    return formatDateTime(this.data?.generated_at);
  }

  get overallLabel() {
    const state = String(this.data?.overall?.state || "inactive");
    return i18n(`admin.interactive_heartbeat.health.overall.${state}.label`);
  }

  get overallDescription() {
    const state = String(this.data?.overall?.state || "inactive");
    return i18n(
      `admin.interactive_heartbeat.health.overall.${state}.description`
    );
  }

  get overallClass() {
    return severityClass(this.data?.overall?.severity);
  }

  get warningItems() {
    return (this.data?.warnings || []).map((warning) => {
      const code = String(warning?.code || "health_unavailable");
      const values = warning?.values || {};
      return {
        code,
        badgeClass: severityClass(warning?.severity),
        title: i18n(
          `admin.interactive_heartbeat.health.warnings.${code}.title`,
          values
        ),
        description: i18n(
          `admin.interactive_heartbeat.health.warnings.${code}.description`,
          values
        ),
      };
    });
  }

  get hasWarnings() {
    return this.warningItems.length > 0;
  }

  get summaryCards() {
    const sessions = this.data?.sessions || {};
    const lovense = this.data?.lovense || {};
    const events = this.data?.events || {};
    const database = this.data?.database || {};

    return [
      {
        label: i18n("admin.interactive_heartbeat.health.cards.open_sessions"),
        value: sessions.available
          ? formatNumber(sessions.open_total)
          : i18n("admin.interactive_heartbeat.health.not_available"),
        detail: i18n(
          "admin.interactive_heartbeat.health.cards.open_sessions_detail",
          {
            active: formatNumber(sessions.active),
            paused: formatNumber(sessions.paused),
          }
        ),
        badgeClass: severityClass(
          Number(sessions.stale_active || 0) > 0 ? "warning" : "ok"
        ),
      },
      {
        label: i18n("admin.interactive_heartbeat.health.cards.lovense"),
        value: lovense.configured
          ? i18n("admin.interactive_heartbeat.health.configured")
          : i18n("admin.interactive_heartbeat.health.not_configured"),
        detail: i18n(
          "admin.interactive_heartbeat.health.cards.lovense_detail",
          {
            success: formatNumber(lovense.successful_callbacks_last_hour),
            rejected: formatNumber(lovense.rejected_callbacks_last_hour),
          }
        ),
        badgeClass: severityClass(lovense.configured ? "ok" : "warning"),
      },
      {
        label: i18n("admin.interactive_heartbeat.health.cards.database"),
        value: database.ready
          ? i18n("admin.interactive_heartbeat.health.ready")
          : i18n("admin.interactive_heartbeat.health.incomplete"),
        detail: i18n(
          "admin.interactive_heartbeat.health.cards.database_detail",
          {
            sessions: formatNumber(database.session_rows),
            participants: formatNumber(database.participant_rows),
          }
        ),
        badgeClass: severityClass(database.ready ? "ok" : "critical"),
      },
      {
        label: i18n("admin.interactive_heartbeat.health.cards.events"),
        value: formatNumber(events.total_count),
        detail: i18n(
          "admin.interactive_heartbeat.health.cards.events_detail",
          {
            warnings: formatNumber(events.warnings_last_24h),
            errors: formatNumber(events.errors_last_24h),
          }
        ),
        badgeClass: severityClass(
          Number(events.errors_last_24h || 0) > 0 ? "warning" : "ok"
        ),
      },
    ];
  }

  get sessionRows() {
    const sessions = this.data?.sessions || {};
    return [
      ["invited", sessions.invited],
      ["setup", sessions.setup],
      ["active", sessions.active],
      ["paused", sessions.paused],
      ["ended", sessions.ended],
      ["declined", sessions.declined],
      ["expired", sessions.expired],
      ["terminal_last_24h", sessions.terminal_last_24h],
      ["stale_active", sessions.stale_active],
    ].map(([key, value]) => ({
      label: i18n(`admin.interactive_heartbeat.health.sessions.${key}`),
      value: formatNumber(value),
    }));
  }

  get dependencyRows() {
    const configuration = this.data?.configuration || {};
    const database = this.data?.database || {};
    return [
      {
        label: i18n("admin.interactive_heartbeat.health.dependencies.heartrate_available"),
        value: yesNoLabel(configuration.heartrate_plugin_available),
      },
      {
        label: i18n("admin.interactive_heartbeat.health.dependencies.heartrate_enabled"),
        value: enabledLabel(configuration.heartrate_plugin_enabled),
      },
      {
        label: i18n("admin.interactive_heartbeat.health.dependencies.async_readings"),
        value: enabledLabel(configuration.async_current_readings_enabled),
      },
      {
        label: i18n("admin.interactive_heartbeat.health.dependencies.database"),
        value: database.ready
          ? i18n("admin.interactive_heartbeat.health.ready")
          : i18n("admin.interactive_heartbeat.health.incomplete"),
      },
      {
        label: i18n("admin.interactive_heartbeat.health.dependencies.lovense"),
        value: configuration.lovense_configured
          ? i18n("admin.interactive_heartbeat.health.configured")
          : i18n("admin.interactive_heartbeat.health.not_configured"),
      },
    ];
  }

  get configurationRows() {
    const configuration = this.data?.configuration || {};
    return [
      ["plugin", enabledLabel(configuration.plugin_enabled)],
      ["navigation", enabledLabel(configuration.navigation_enabled)],
      ["test_lab", enabledLabel(configuration.test_lab_enabled)],
      ["allowed_groups", formatNumber(configuration.allowed_groups_count)],
      ["lovense_app", String(configuration.lovense_app_type || "-")],
      ["callback_ttl", `${formatNumber(configuration.callback_ttl_seconds)} s`],
      ["invite_expiry", `${formatNumber(configuration.invite_expiry_minutes)} min`],
      ["allow_nobody", enabledLabel(configuration.allow_nobody_invitation_preference)],
      ["max_open", formatNumber(configuration.max_open_sessions_per_user)],
      ["decline_cooldown", `${formatNumber(configuration.declined_invite_cooldown_minutes)} min`],
      ["invites_per_day", formatNumber(configuration.invites_per_day)],
      ["max_invitation_list", formatNumber(configuration.max_invitation_list_members)],
      ["retention", `${formatNumber(configuration.completed_session_retention_days)} days`],
      ["presence_timeout", `${formatNumber(configuration.presence_timeout_seconds)} s`],
      ["signal_unstable", `${formatNumber(configuration.signal_unstable_seconds)} s`],
      ["signal_stale", `${formatNumber(configuration.signal_stale_seconds)} s`],
      ["signal_poll", `${formatNumber(configuration.signal_poll_ms)} ms`],
    ].map(([key, value]) => ({
      label: i18n(`admin.interactive_heartbeat.health.configuration.${key}`),
      value,
    }));
  }

  get privacyRows() {
    const privacy = this.data?.privacy || {};
    const events = this.data?.events || {};
    return [
      {
        label: i18n("admin.interactive_heartbeat.health.privacy.heartbeat_history"),
        value: yesNoLabel(privacy.heartbeat_history_stored),
        detail: i18n(
          "admin.interactive_heartbeat.health.privacy.heartbeat_history_detail"
        ),
      },
      {
        label: i18n("admin.interactive_heartbeat.health.privacy.callback_state"),
        value: i18n("admin.interactive_heartbeat.health.privacy.latest_only"),
        detail: i18n(
          "admin.interactive_heartbeat.health.privacy.callback_state_detail",
          { seconds: formatNumber(privacy.callback_state_ttl_seconds) }
        ),
      },
      {
        label: i18n("admin.interactive_heartbeat.health.privacy.event_log"),
        value: i18n("admin.interactive_heartbeat.health.privacy.metadata_only"),
        detail: i18n(
          "admin.interactive_heartbeat.health.privacy.event_log_detail",
          {
            days: formatNumber(events.retention_days),
            max: formatNumber(events.max_events),
          }
        ),
      },
    ];
  }
}
