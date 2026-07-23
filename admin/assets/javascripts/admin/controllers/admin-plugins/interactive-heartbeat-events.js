import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";
import { i18n } from "discourse-i18n";

const CATEGORIES = new Set([
  "session",
  "invitation",
  "consent",
  "lovense",
  "security",
  "cleanup",
  "system",
]);
const SEVERITIES = new Set(["info", "warning", "error"]);
const EVENTS = new Set([
  "invitation_create",
  "invitation_accept",
  "invitation_decline",
  "invitation_preference",
  "invitation_member",
  "session_start",
  "session_pause",
  "session_end",
  "completed_history_clear",
  "permission_grant",
  "permission_revoke",
  "configuration_update",
  "lovense_token",
  "lovense_callback",
  "request_rate_limit",
  "cleanup",
  "unknown",
]);
const RESULTS = new Set([
  "success",
  "created",
  "accepted",
  "declined",
  "updated",
  "added",
  "removed",
  "started",
  "paused",
  "ended",
  "cleared",
  "granted",
  "revoked",
  "proposed",
  "no_change",
  "blocked",
  "limit_reached",
  "not_configured",
  "provider_error",
  "rejected",
  "rate_limited",
  "invalid",
  "payload_too_large",
  "temporarily_unavailable",
  "failed",
  "unknown",
]);
const CLIENT_CONTEXTS = new Set([
  "desktop_browser",
  "mobile_browser",
  "embedded_webview",
  "server",
  "unknown",
]);

function formatDateTime(value) {
  const date = new Date(value);
  if (!value || Number.isNaN(date.getTime())) {
    return i18n("admin.interactive_heartbeat.events.not_available");
  }
  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "medium",
  }).format(date);
}

function extractError(error) {
  return (
    error?.jqXHR?.responseJSON?.errors?.[0] ||
    error?.responseJSON?.errors?.[0] ||
    error?.message ||
    i18n("admin.interactive_heartbeat.events.load_error")
  );
}

function normalizedKey(value, allowed, fallback = "unknown") {
  const normalized = String(value || "");
  return allowed.has(normalized) ? normalized : fallback;
}

export default class AdminPluginsInteractiveHeartbeatEventsController extends Controller {
  @tracked data = null;
  @tracked isLoading = false;
  @tracked error = null;
  @tracked categoryFilter = "";
  @tracked severityFilter = "";

  resetState() {
    this.data = null;
    this.isLoading = false;
    this.error = null;
    this.categoryFilter = "";
    this.severityFilter = "";
  }

  @action
  async loadEvents() {
    if (this.isLoading) {
      return;
    }
    this.isLoading = true;
    this.error = null;

    const query = new URLSearchParams({ limit: "200" });
    if (this.categoryFilter) {
      query.set("category", this.categoryFilter);
    }
    if (this.severityFilter) {
      query.set("severity", this.severityFilter);
    }

    try {
      this.data = await ajax(
        `/admin/plugins/interactive-heartbeat/events.json?${query.toString()}`
      );
    } catch (error) {
      this.error = extractError(error);
    } finally {
      this.isLoading = false;
    }
  }

  @action
  changeCategory(event) {
    this.categoryFilter = event.target.value;
    this.loadEvents();
  }

  @action
  changeSeverity(event) {
    this.severityFilter = event.target.value;
    this.loadEvents();
  }

  get generatedAtLabel() {
    return formatDateTime(this.data?.generated_at);
  }

  get retentionLabel() {
    return i18n("admin.interactive_heartbeat.events.retention", {
      days: Number(this.data?.retention_days || 7),
      max: Number(this.data?.max_events || 500),
    });
  }

  get totalLabel() {
    return i18n("admin.interactive_heartbeat.events.total", {
      count: Number(this.data?.total_events || 0),
    });
  }

  get eventRows() {
    return (this.data?.events || []).map((entry) => {
      const severity = normalizedKey(entry?.severity, SEVERITIES, "info");
      const category = normalizedKey(entry?.category, CATEGORIES, "system");
      const event = normalizedKey(entry?.event, EVENTS);
      const result = normalizedKey(entry?.result, RESULTS);
      const clientContext = normalizedKey(
        entry?.client_context,
        CLIENT_CONTEXTS
      );

      return {
        id: String(entry?.id || `${entry?.occurred_at_ms}-${event}-${result}`),
        occurredAt: formatDateTime(entry?.occurred_at),
        severity,
        severityClass: `is-${severity}`,
        severityLabel: i18n(
          `admin.interactive_heartbeat.events.severities.${severity}`
        ),
        categoryLabel: i18n(
          `admin.interactive_heartbeat.events.categories.${category}`
        ),
        eventLabel: i18n(
          `admin.interactive_heartbeat.events.event_names.${event}`
        ),
        resultLabel: i18n(
          `admin.interactive_heartbeat.events.results.${result}`
        ),
        clientLabel: i18n(
          `admin.interactive_heartbeat.events.client_contexts.${clientContext}`
        ),
      };
    });
  }

  get hasEvents() {
    return this.eventRows.length > 0;
  }
}
