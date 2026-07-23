import RouteTemplate from "ember-route-template";
import { on } from "@ember/modifier";
import { i18n } from "discourse-i18n";

export default RouteTemplate(
  <template>
    <style>
      .ih-health {
        --ih-surface: var(--secondary);
        --ih-border: var(--primary-low);
        --ih-muted: var(--primary-medium);
        display: flex;
        flex-direction: column;
        gap: 1rem;
      }

      .ih-health h1,
      .ih-health h2,
      .ih-health h3,
      .ih-health p,
      .ih-health ul {
        margin: 0;
      }

      .ih-health__hero,
      .ih-health__panel,
      .ih-health__card {
        background: var(--ih-surface);
        border: 1px solid var(--ih-border);
        border-radius: 18px;
        box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
      }

      .ih-health__hero,
      .ih-health__panel {
        padding: 1rem 1.125rem;
      }

      .ih-health__header,
      .ih-health__panel-header {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 1rem;
      }

      .ih-health__copy {
        display: flex;
        flex-direction: column;
        gap: 0.3rem;
        min-width: 0;
      }

      .ih-health__muted,
      .ih-health__detail {
        color: var(--ih-muted);
        font-size: var(--font-down-1);
      }

      .ih-health__actions {
        display: flex;
        flex-wrap: wrap;
        justify-content: flex-end;
        gap: 0.65rem;
      }

      .ih-health__status,
      .ih-health__badge {
        display: inline-flex;
        align-items: center;
        border: 1px solid var(--ih-border);
        border-radius: 999px;
        padding: 0.35rem 0.7rem;
        background: var(--primary-very-low);
        font-weight: 700;
      }

      .ih-health__status.is-ok,
      .ih-health__badge.is-ok {
        border-color: var(--success-low-mid);
        background: var(--success-low);
        color: var(--success);
      }

      .ih-health__status.is-warning,
      .ih-health__badge.is-warning {
        border-color: var(--tertiary-low);
        background: var(--tertiary-very-low);
        color: var(--tertiary-high);
      }

      .ih-health__status.is-critical,
      .ih-health__badge.is-critical {
        border-color: var(--danger-low-mid);
        background: var(--danger-low);
        color: var(--danger);
      }

      .ih-health__status.is-info,
      .ih-health__badge.is-info {
        background: var(--primary-very-low);
        color: var(--primary-medium);
      }

      .ih-health__grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
        gap: 1rem;
      }

      .ih-health__card {
        padding: 1rem;
      }

      .ih-health__card strong {
        display: block;
        margin: 0.25rem 0;
        font-size: var(--font-up-2);
      }

      .ih-health__warning-list {
        display: grid;
        gap: 0.7rem;
        padding: 0;
        list-style: none;
      }

      .ih-health__warning {
        display: grid;
        grid-template-columns: auto minmax(0, 1fr);
        gap: 0.75rem;
        align-items: start;
        padding: 0.75rem;
        border: 1px solid var(--ih-border);
        border-radius: 12px;
      }

      .ih-health__rows {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 0.65rem 1rem;
        margin-top: 0.85rem;
      }

      .ih-health__row {
        display: flex;
        justify-content: space-between;
        gap: 1rem;
        padding: 0.7rem 0;
        border-bottom: 1px solid var(--primary-low);
      }

      .ih-health__privacy-row {
        display: grid;
        gap: 0.2rem;
        padding: 0.75rem 0;
        border-bottom: 1px solid var(--primary-low);
      }

      .ih-health__error {
        border-color: var(--danger-low-mid);
        background: var(--danger-low);
        color: var(--danger);
      }

      @media (max-width: 760px) {
        .ih-health__header,
        .ih-health__panel-header {
          flex-direction: column;
        }

        .ih-health__rows {
          grid-template-columns: 1fr;
        }
      }
    </style>

    <div class="ih-health">
      <section class="ih-health__hero">
        <div class="ih-health__header">
          <div class="ih-health__copy">
            <a href="/admin/plugins/interactive-heartbeat">
              {{i18n "admin.interactive_heartbeat.health.back_to_overview"}}
            </a>
            <h1>{{i18n "admin.interactive_heartbeat.health.title"}}</h1>
            <p class="ih-health__muted">
              {{i18n "admin.interactive_heartbeat.health.description"}}
            </p>
          </div>
          <div class="ih-health__actions">
            {{#if this.hasData}}
              <span class="ih-health__status {{this.overallClass}}">
                {{this.overallLabel}}
              </span>
            {{/if}}
            <button
              type="button"
              class="btn btn-primary"
              disabled={{this.isLoading}}
              {{on "click" this.loadHealth}}
            >
              {{if
                this.isLoading
                (i18n "admin.interactive_heartbeat.health.refreshing")
                (i18n "admin.interactive_heartbeat.health.refresh")
              }}
            </button>
          </div>
        </div>
        {{#if this.hasData}}
          <p class="ih-health__detail">
            {{this.overallDescription}} ·
            {{i18n
              "admin.interactive_heartbeat.health.last_checked"
              time=this.generatedAtLabel
            }}
          </p>
        {{/if}}
      </section>

      {{#if this.error}}
        <section class="ih-health__panel ih-health__error">{{this.error}}</section>
      {{/if}}

      {{#if this.hasData}}
        <section class="ih-health__grid">
          {{#each this.summaryCards as |card|}}
            <article class="ih-health__card">
              <span class="ih-health__badge {{card.badgeClass}}">{{card.label}}</span>
              <strong>{{card.value}}</strong>
              <p class="ih-health__detail">{{card.detail}}</p>
            </article>
          {{/each}}
        </section>

        <section class="ih-health__panel">
          <div class="ih-health__panel-header">
            <div class="ih-health__copy">
              <h2>{{i18n "admin.interactive_heartbeat.health.status_title"}}</h2>
              <p class="ih-health__muted">
                {{i18n "admin.interactive_heartbeat.health.status_description"}}
              </p>
            </div>
          </div>
          {{#if this.hasWarnings}}
            <ul class="ih-health__warning-list">
              {{#each this.warningItems as |warning|}}
                <li class="ih-health__warning">
                  <span class="ih-health__badge {{warning.badgeClass}}">!</span>
                  <div>
                    <strong>{{warning.title}}</strong>
                    <p class="ih-health__detail">{{warning.description}}</p>
                  </div>
                </li>
              {{/each}}
            </ul>
          {{else}}
            <p>{{i18n "admin.interactive_heartbeat.health.no_warnings"}}</p>
          {{/if}}
        </section>

        <section class="ih-health__panel">
          <div class="ih-health__copy">
            <h2>{{i18n "admin.interactive_heartbeat.health.sessions_title"}}</h2>
            <p class="ih-health__muted">
              {{i18n "admin.interactive_heartbeat.health.sessions_description"}}
            </p>
          </div>
          <div class="ih-health__rows">
            {{#each this.sessionRows as |row|}}
              <div class="ih-health__row"><span>{{row.label}}</span><strong>{{row.value}}</strong></div>
            {{/each}}
          </div>
        </section>

        <section class="ih-health__panel">
          <div class="ih-health__copy">
            <h2>{{i18n "admin.interactive_heartbeat.health.dependencies_title"}}</h2>
            <p class="ih-health__muted">
              {{i18n "admin.interactive_heartbeat.health.dependencies_description"}}
            </p>
          </div>
          <div class="ih-health__rows">
            {{#each this.dependencyRows as |row|}}
              <div class="ih-health__row"><span>{{row.label}}</span><strong>{{row.value}}</strong></div>
            {{/each}}
          </div>
        </section>

        <section class="ih-health__panel">
          <div class="ih-health__copy">
            <h2>{{i18n "admin.interactive_heartbeat.health.configuration_title"}}</h2>
            <p class="ih-health__muted">
              {{i18n "admin.interactive_heartbeat.health.configuration_description"}}
            </p>
          </div>
          <div class="ih-health__rows">
            {{#each this.configurationRows as |row|}}
              <div class="ih-health__row"><span>{{row.label}}</span><strong>{{row.value}}</strong></div>
            {{/each}}
          </div>
        </section>

        <section class="ih-health__panel">
          <div class="ih-health__copy">
            <h2>{{i18n "admin.interactive_heartbeat.health.privacy_title"}}</h2>
            <p class="ih-health__muted">
              {{i18n "admin.interactive_heartbeat.health.privacy_description"}}
            </p>
          </div>
          {{#each this.privacyRows as |row|}}
            <div class="ih-health__privacy-row">
              <div class="ih-health__row"><span>{{row.label}}</span><strong>{{row.value}}</strong></div>
              <p class="ih-health__detail">{{row.detail}}</p>
            </div>
          {{/each}}
        </section>
      {{else if this.isLoading}}
        <section class="ih-health__panel">
          {{i18n "admin.interactive_heartbeat.health.loading"}}
        </section>
      {{/if}}
    </div>
  </template>
);
