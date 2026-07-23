import RouteTemplate from "ember-route-template";
import { on } from "@ember/modifier";
import { i18n } from "discourse-i18n";

export default RouteTemplate(
  <template>
    <style>
      .ih-events {
        --ih-surface: var(--secondary);
        --ih-border: var(--primary-low);
        --ih-muted: var(--primary-medium);
        display: flex;
        flex-direction: column;
        gap: 1rem;
      }

      .ih-events h1,
      .ih-events h2,
      .ih-events p {
        margin: 0;
      }

      .ih-events__hero,
      .ih-events__panel {
        background: var(--ih-surface);
        border: 1px solid var(--ih-border);
        border-radius: 18px;
        box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
        padding: 1rem 1.125rem;
      }

      .ih-events__header,
      .ih-events__toolbar {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 1rem;
      }

      .ih-events__copy {
        display: flex;
        flex-direction: column;
        gap: 0.3rem;
      }

      .ih-events__muted {
        color: var(--ih-muted);
        font-size: var(--font-down-1);
      }

      .ih-events__actions {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        justify-content: flex-end;
        gap: 0.65rem;
      }

      .ih-events__filters {
        display: flex;
        flex-wrap: wrap;
        gap: 0.75rem;
      }

      .ih-events__field {
        display: grid;
        gap: 0.25rem;
      }

      .ih-events__table-wrap {
        overflow-x: auto;
        margin-top: 1rem;
      }

      .ih-events__table {
        width: 100%;
        border-collapse: collapse;
      }

      .ih-events__table th,
      .ih-events__table td {
        padding: 0.75rem;
        border-bottom: 1px solid var(--primary-low);
        text-align: left;
        vertical-align: top;
        white-space: nowrap;
      }

      .ih-events__severity {
        display: inline-flex;
        border: 1px solid var(--ih-border);
        border-radius: 999px;
        padding: 0.25rem 0.55rem;
        font-weight: 700;
      }

      .ih-events__severity.is-warning {
        border-color: var(--tertiary-low);
        background: var(--tertiary-very-low);
        color: var(--tertiary-high);
      }

      .ih-events__severity.is-error {
        border-color: var(--danger-low-mid);
        background: var(--danger-low);
        color: var(--danger);
      }

      .ih-events__severity.is-info {
        background: var(--primary-very-low);
        color: var(--primary-medium);
      }

      .ih-events__error {
        border-color: var(--danger-low-mid);
        background: var(--danger-low);
        color: var(--danger);
      }

      @media (max-width: 700px) {
        .ih-events__header,
        .ih-events__toolbar {
          flex-direction: column;
        }

        .ih-events__actions {
          justify-content: flex-start;
        }
      }
    </style>

    <div class="ih-events">
      <section class="ih-events__hero">
        <div class="ih-events__header">
          <div class="ih-events__copy">
            <h1>{{i18n "admin.interactive_heartbeat.events.title"}}</h1>
            <p class="ih-events__muted">
              {{i18n "admin.interactive_heartbeat.events.description"}}
            </p>
          </div>
          <div class="ih-events__actions">
            <button
              type="button"
              class="btn"
              disabled={{@controller.isLoading}}
              {{on "click" @controller.loadEvents}}
            >
              {{if
                @controller.isLoading
                (i18n "admin.interactive_heartbeat.events.refreshing")
                (i18n "admin.interactive_heartbeat.events.refresh")
              }}
            </button>
            <a class="btn" href="/admin/plugins/interactive-heartbeat-health">
              {{i18n "admin.interactive_heartbeat.health.short_title"}}
            </a>
            <a
              class="btn"
              href="/admin/site_settings/category/all_results?filter=interactive_heartbeat"
            >
              {{i18n "admin.interactive_heartbeat.open_settings"}}
            </a>
            <a class="btn" href="/admin/plugins/interactive-heartbeat">
              {{i18n "admin.interactive_heartbeat.events.back_to_overview"}}
            </a>
          </div>
        </div>
      </section>

      {{#if @controller.error}}
        <section class="ih-events__panel ih-events__error">{{@controller.error}}</section>
      {{/if}}

      <section class="ih-events__panel">
        <div class="ih-events__toolbar">
          <div class="ih-events__copy">
            <h2>{{i18n "admin.interactive_heartbeat.events.recent_title"}}</h2>
            <p class="ih-events__muted">
              {{i18n "admin.interactive_heartbeat.events.recent_description"}}
            </p>
            {{#if @controller.data}}
              <p class="ih-events__muted">
                {{@controller.totalLabel}} · {{@controller.retentionLabel}} ·
                {{i18n
                  "admin.interactive_heartbeat.events.last_checked"
                  time=@controller.generatedAtLabel
                }}
              </p>
            {{/if}}
          </div>

          <div class="ih-events__filters">
            <label class="ih-events__field">
              <span>{{i18n "admin.interactive_heartbeat.events.category_filter"}}</span>
              <select {{on "change" @controller.changeCategory}}>
                <option value="">{{i18n "admin.interactive_heartbeat.events.all_categories"}}</option>
                <option value="session">{{i18n "admin.interactive_heartbeat.events.categories.session"}}</option>
                <option value="invitation">{{i18n "admin.interactive_heartbeat.events.categories.invitation"}}</option>
                <option value="consent">{{i18n "admin.interactive_heartbeat.events.categories.consent"}}</option>
                <option value="lovense">{{i18n "admin.interactive_heartbeat.events.categories.lovense"}}</option>
                <option value="security">{{i18n "admin.interactive_heartbeat.events.categories.security"}}</option>
                <option value="cleanup">{{i18n "admin.interactive_heartbeat.events.categories.cleanup"}}</option>
                <option value="system">{{i18n "admin.interactive_heartbeat.events.categories.system"}}</option>
              </select>
            </label>

            <label class="ih-events__field">
              <span>{{i18n "admin.interactive_heartbeat.events.severity_filter"}}</span>
              <select {{on "change" @controller.changeSeverity}}>
                <option value="">{{i18n "admin.interactive_heartbeat.events.all_severities"}}</option>
                <option value="info">{{i18n "admin.interactive_heartbeat.events.severities.info"}}</option>
                <option value="warning">{{i18n "admin.interactive_heartbeat.events.severities.warning"}}</option>
                <option value="error">{{i18n "admin.interactive_heartbeat.events.severities.error"}}</option>
              </select>
            </label>
          </div>
        </div>

        {{#if @controller.hasEvents}}
          <div class="ih-events__table-wrap">
            <table class="ih-events__table">
              <thead>
                <tr>
                  <th>{{i18n "admin.interactive_heartbeat.events.columns.time"}}</th>
                  <th>{{i18n "admin.interactive_heartbeat.events.columns.severity"}}</th>
                  <th>{{i18n "admin.interactive_heartbeat.events.columns.category"}}</th>
                  <th>{{i18n "admin.interactive_heartbeat.events.columns.event"}}</th>
                  <th>{{i18n "admin.interactive_heartbeat.events.columns.result"}}</th>
                  <th>{{i18n "admin.interactive_heartbeat.events.columns.client"}}</th>
                </tr>
              </thead>
              <tbody>
                {{#each @controller.eventRows as |row|}}
                  <tr>
                    <td>{{row.occurredAt}}</td>
                    <td><span class="ih-events__severity {{row.severityClass}}">{{row.severityLabel}}</span></td>
                    <td>{{row.categoryLabel}}</td>
                    <td>{{row.eventLabel}}</td>
                    <td>{{row.resultLabel}}</td>
                    <td>{{row.clientLabel}}</td>
                  </tr>
                {{/each}}
              </tbody>
            </table>
          </div>
        {{else if @controller.isLoading}}
          <p>{{i18n "admin.interactive_heartbeat.events.loading"}}</p>
        {{else}}
          <p>{{i18n "admin.interactive_heartbeat.events.no_events"}}</p>
        {{/if}}
      </section>
    </div>
  </template>
);
