import RouteTemplate from "ember-route-template";
import { i18n } from "discourse-i18n";

export default RouteTemplate(
  <template>
    <style>
      .interactive-heartbeat-admin-landing {
        --ih-surface: var(--secondary);
        --ih-border: var(--primary-low);
        --ih-muted: var(--primary-medium);
        display: flex;
        flex-direction: column;
        gap: 1rem;
      }

      .interactive-heartbeat-admin-landing h1,
      .interactive-heartbeat-admin-landing h2,
      .interactive-heartbeat-admin-landing h3,
      .interactive-heartbeat-admin-landing p {
        margin: 0;
      }

      .ih-admin__hero,
      .ih-admin__card {
        background: var(--ih-surface);
        border: 1px solid var(--ih-border);
        border-radius: 18px;
        box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
      }

      .ih-admin__hero {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 1rem;
        padding: 1.25rem 1.35rem;
      }

      .ih-admin__hero-copy,
      .ih-admin__section-copy,
      .ih-admin__card-title {
        display: flex;
        flex-direction: column;
        gap: 0.35rem;
      }

      .ih-admin__hero-copy p,
      .ih-admin__section-copy p,
      .ih-admin__card p {
        color: var(--ih-muted);
      }

      .ih-admin__section-header {
        padding: 0 0.25rem;
      }

      .ih-admin__grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
        gap: 1rem;
      }

      .ih-admin__card {
        display: flex;
        flex-direction: column;
        gap: 0.85rem;
        min-height: 170px;
        padding: 1rem 1.1rem;
        color: var(--primary);
        text-decoration: none;
        transition: 0.12s ease;
      }

      .ih-admin__card:hover,
      .ih-admin__card:focus {
        border-color: var(--tertiary-medium);
        color: var(--primary);
        text-decoration: none;
        transform: translateY(-1px);
        box-shadow: 0 6px 18px rgba(0, 0, 0, 0.06);
      }

      .ih-admin__card.is-primary {
        border-color: var(--tertiary-low);
        background: linear-gradient(180deg, var(--secondary), var(--tertiary-very-low));
      }

      .ih-admin__badge {
        display: inline-flex;
        width: max-content;
        border: 1px solid var(--primary-low);
        border-radius: 999px;
        background: var(--primary-very-low);
        color: var(--primary-medium);
        font-size: var(--font-down-1);
        padding: 0.35rem 0.55rem;
      }

      .ih-admin__badge.is-primary {
        border-color: var(--tertiary-low);
        background: var(--tertiary-low);
        color: var(--tertiary);
      }

      .ih-admin__card-action {
        margin-top: auto;
        color: var(--tertiary);
        font-weight: 600;
      }

      @media (max-width: 700px) {
        .ih-admin__hero {
          flex-direction: column;
        }
      }
    </style>

    <div class="interactive-heartbeat-admin-landing">
      <section class="ih-admin__hero">
        <div class="ih-admin__hero-copy">
          <h1>{{i18n "admin.interactive_heartbeat.title"}}</h1>
          <p>{{i18n "admin.interactive_heartbeat.description"}}</p>
        </div>
        <a
          class="btn btn-primary"
          href="/admin/site_settings/category/all_results?filter=interactive_heartbeat"
        >
          {{i18n "admin.interactive_heartbeat.open_settings"}}
        </a>
      </section>

      <div class="ih-admin__section-header">
        <div class="ih-admin__section-copy">
          <h2>{{i18n "admin.interactive_heartbeat.overview_title"}}</h2>
          <p>{{i18n "admin.interactive_heartbeat.overview_description"}}</p>
        </div>
      </div>

      <section class="ih-admin__grid">
        <a
          class="ih-admin__card is-primary"
          href="/admin/site_settings/category/all_results?filter=interactive_heartbeat"
        >
          <div class="ih-admin__card-title">
            <span class="ih-admin__badge is-primary">
              {{i18n "admin.interactive_heartbeat.category_configuration"}}
            </span>
            <h3>{{i18n "admin.interactive_heartbeat.open_settings"}}</h3>
          </div>
          <p>{{i18n "admin.interactive_heartbeat.settings_description"}}</p>
          <span class="ih-admin__card-action">
            {{i18n "admin.interactive_heartbeat.open_settings"}}
          </span>
        </a>

        <a
          class="ih-admin__card"
          href="/admin/plugins/interactive-heartbeat-health"
        >
          <div class="ih-admin__card-title">
            <span class="ih-admin__badge">
              {{i18n "admin.interactive_heartbeat.category_monitoring"}}
            </span>
            <h3>{{i18n "admin.interactive_heartbeat.health.short_title"}}</h3>
          </div>
          <p>{{i18n "admin.interactive_heartbeat.health.description"}}</p>
          <span class="ih-admin__card-action">
            {{i18n "admin.interactive_heartbeat.open_tool"}}
          </span>
        </a>

        <a
          class="ih-admin__card"
          href="/admin/plugins/interactive-heartbeat-events"
        >
          <div class="ih-admin__card-title">
            <span class="ih-admin__badge">
              {{i18n "admin.interactive_heartbeat.category_monitoring"}}
            </span>
            <h3>{{i18n "admin.interactive_heartbeat.events.short_title"}}</h3>
          </div>
          <p>{{i18n "admin.interactive_heartbeat.events.description"}}</p>
          <span class="ih-admin__card-action">
            {{i18n "admin.interactive_heartbeat.open_tool"}}
          </span>
        </a>
      </section>
    </div>
  </template>
);
