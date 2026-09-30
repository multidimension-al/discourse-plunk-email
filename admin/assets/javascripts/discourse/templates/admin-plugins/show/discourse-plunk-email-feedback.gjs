import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { eq } from "truth-helpers";
import getURL from "discourse/lib/get-url";
import DButton from "discourse/ui-kit/d-button";
import DCopyButton from "discourse/ui-kit/d-copy-button";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import { i18n } from "discourse-i18n";

const STATUS_FILTERS = [
  "pending",
  "retrying",
  "failed",
  "unmatched",
  "conflict",
  "processed",
];
const KINDS = ["contact.unsubscribed", "email.complaint", "email.bounce"];
const COUNT_KEYS = [
  "pending",
  "retrying",
  "failed",
  "unmatched",
  "conflict",
  "processed",
  "identity_conflicts",
];

function when(value) {
  return value
    ? new Date(value).toLocaleString()
    : i18n("discourse_plunk.admin.never");
}

function kindLabel(kind) {
  return i18n(`discourse_plunk.admin.kinds.${kind.replace(".", "_")}`);
}

function displayStatus(event) {
  return event.status === "failed" && event.next_attempt_at
    ? "retrying"
    : event.status;
}

function statusLabel(event) {
  return i18n(`discourse_plunk.admin.statuses.${displayStatus(event)}`);
}

function statusFilterLabel(status) {
  return i18n(`discourse_plunk.admin.statuses.${status}`);
}

function countLabel(key) {
  return i18n(`discourse_plunk.admin.counts.${key}`);
}

function countValue(counts, key) {
  return counts?.[key] ?? 0;
}

function yesNo(value) {
  return i18n(`discourse_plunk.admin.${value ? "yes_value" : "no_value"}`);
}

function preferenceChanges(event) {
  const changes = event.preference_changes?.changes || {};
  return Object.entries(changes).map(
    ([column, [from, to]]) => `${column}: ${from} → ${to}`
  );
}

function canReprocess(event) {
  return event.status !== "processed";
}

function userAdminUrl(event) {
  return getURL(`/admin/users/${event.user_id}/${event.username}`);
}

function show(value) {
  return value === null || value === undefined || value === "" ? "—" : value;
}

<template>
  <div class="plunk-feedback-admin admin-detail">
    <DPageSubheader
      @titleLabel={{i18n "discourse_plunk.admin.page_title"}}
      @descriptionLabel={{i18n "discourse_plunk.admin.page_description"}}
    >
      <:actions as |actions|>
        <actions.Default
          @label="discourse_plunk.admin.refresh"
          @action={{@controller.load}}
          class="plunk-feedback-admin__refresh"
        />
      </:actions>
    </DPageSubheader>

    {{#if @controller.loadFailed}}
      <p class="plunk-feedback-admin__warning">
        {{i18n "discourse_plunk.admin.load_failed"}}
      </p>
    {{/if}}

    {{#if @controller.status}}
      <section class="plunk-feedback-admin__configuration">
        <h3>{{i18n "discourse_plunk.admin.configuration"}}</h3>
        <dl class="plunk-feedback-admin__grid">
          <dt>{{i18n "discourse_plunk.admin.enabled"}}</dt>
          <dd>{{yesNo @controller.status.enabled}}</dd>
          <dt>{{i18n "discourse_plunk.admin.secret"}}</dt>
          <dd>
            {{#if @controller.status.secret_configured}}
              {{i18n "discourse_plunk.admin.configured"}}
            {{else}}
              <span class="plunk-feedback-admin__warning">{{i18n
                  "discourse_plunk.admin.not_configured"
                }}</span>
            {{/if}}
          </dd>
          <dt>{{i18n "discourse_plunk.admin.previous_secret"}}</dt>
          <dd>{{yesNo @controller.status.previous_secret_configured}}</dd>
          <dt>{{i18n "discourse_plunk.admin.recovery"}}</dt>
          <dd>
            {{#if @controller.status.recovery_healthy}}
              {{i18n "discourse_plunk.admin.healthy"}}
            {{else}}
              <span class="plunk-feedback-admin__warning">{{i18n
                  "discourse_plunk.admin.unhealthy"
                }}</span>
            {{/if}}
          </dd>
          <dt>{{i18n "discourse_plunk.admin.retention"}}</dt>
          <dd>{{i18n
              "discourse_plunk.admin.retention_days"
              count=@controller.status.retention_days
            }}</dd>
          <dt>{{i18n "discourse_plunk.admin.optional_preferences"}}</dt>
          <dd>
            {{#each @controller.status.optional_preferences as |column|}}
              <code>{{column}}</code>
            {{/each}}
          </dd>
        </dl>
      </section>

      <section class="plunk-feedback-admin__webhooks">
        <h3>{{i18n "discourse_plunk.admin.webhooks"}}</h3>
        <p>{{i18n "discourse_plunk.admin.webhooks_help"}}</p>
        <table class="plunk-feedback-admin__urls">
          <thead>
            <tr>
              <th>{{i18n "discourse_plunk.admin.trigger"}}</th>
              <th>{{i18n "discourse_plunk.admin.url"}}</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {{#each @controller.status.webhooks as |webhook|}}
              <tr>
                <td><code>{{webhook.trigger}}</code></td>
                <td><code>{{webhook.url}}</code></td>
                <td>
                  <DCopyButton
                    @value={{webhook.url}}
                    @translatedLabel={{i18n "discourse_plunk.admin.copy"}}
                    @translatedLabelAfterCopy={{i18n
                      "discourse_plunk.admin.copied"
                    }}
                    @copyClass="btn-default btn-small"
                  />
                </td>
              </tr>
            {{/each}}
          </tbody>
        </table>
      </section>

      <section class="plunk-feedback-admin__activity">
        <h3>{{i18n "discourse_plunk.admin.activity"}}</h3>
        <dl class="plunk-feedback-admin__grid">
          <dt>{{i18n "discourse_plunk.admin.last_received"}}</dt>
          <dd>{{when @controller.status.last_received_at}}</dd>
          <dt>{{i18n "discourse_plunk.admin.last_processed"}}</dt>
          <dd>{{when @controller.status.last_processed_at}}</dd>
        </dl>
        <ul class="plunk-feedback-admin__counts">
          {{#each COUNT_KEYS as |key|}}
            <li><strong>{{countValue @controller.status.counts key}}</strong>{{countLabel
                key
              }}</li>
          {{/each}}
        </ul>
      </section>
    {{/if}}

    <section class="plunk-feedback-admin__list">
      <h3>{{i18n "discourse_plunk.admin.events"}}</h3>
      <form
        class="plunk-feedback-admin__search"
        {{on "submit" @controller.submitSearch}}
      >
        <input
          type="search"
          value={{@controller.query}}
          placeholder={{i18n "discourse_plunk.admin.search_placeholder"}}
          aria-label={{i18n "discourse_plunk.admin.search"}}
          {{on "input" @controller.updateQuery}}
        />
        <select
          aria-label={{i18n "discourse_plunk.admin.all_statuses"}}
          {{on "change" @controller.updateStatusFilter}}
        >
          <option value="">{{i18n "discourse_plunk.admin.all_statuses"}}</option>
          {{#each STATUS_FILTERS as |status|}}
            <option
              value={{status}}
              selected={{eq status @controller.statusFilter}}
            >{{statusFilterLabel status}}</option>
          {{/each}}
        </select>
        <select
          aria-label={{i18n "discourse_plunk.admin.all_kinds"}}
          {{on "change" @controller.updateKindFilter}}
        >
          <option value="">{{i18n "discourse_plunk.admin.all_kinds"}}</option>
          {{#each KINDS as |kind|}}
            <option
              value={{kind}}
              selected={{eq kind @controller.kindFilter}}
            >{{kindLabel kind}}</option>
          {{/each}}
        </select>
        <DButton
          @label="discourse_plunk.admin.search"
          @action={{@controller.search}}
          class="btn-primary"
        />
      </form>

      {{#if @controller.selected}}
        {{#let @controller.selected as |event|}}
          <div class="plunk-feedback-admin__detail">
            <h3>{{i18n "discourse_plunk.admin.details"}}
              #{{event.id}}</h3>

            <h3>{{i18n "discourse_plunk.admin.detail.receipt"}}</h3>
            <dl class="plunk-feedback-admin__grid">
              <dt>{{i18n "discourse_plunk.admin.detail.kind"}}</dt>
              <dd><code>{{event.kind}}</code></dd>
              <dt>{{i18n "discourse_plunk.admin.col_status"}}</dt>
              <dd
                class="plunk-feedback-admin__status--{{displayStatus event}}"
              >{{statusLabel event}}
                ({{show event.outcome}})</dd>
              <dt>{{i18n "discourse_plunk.admin.detail.source"}}</dt>
              <dd>{{event.source}}</dd>
              <dt>{{i18n "discourse_plunk.admin.detail.received_at"}}</dt>
              <dd>{{when event.received_at}}</dd>
              <dt>{{i18n "discourse_plunk.admin.detail.processed_at"}}</dt>
              <dd>{{when event.processed_at}}</dd>
            </dl>

            <h3>{{i18n "discourse_plunk.admin.detail.delivery"}}</h3>
            <dl class="plunk-feedback-admin__grid">
              <dt>{{i18n "discourse_plunk.admin.detail.workflow"}}</dt>
              <dd><code>{{event.workflow_id}}</code>
                {{show event.workflow_name}}</dd>
              <dt>{{i18n "discourse_plunk.admin.detail.execution"}}</dt>
              <dd><code>{{event.execution_id}}</code></dd>
              <dt>{{i18n
                  "discourse_plunk.admin.detail.execution_started_at"
                }}</dt>
              <dd>{{when event.execution_started_at}}</dd>
              <dt>{{i18n "discourse_plunk.admin.detail.delivery_count"}}</dt>
              <dd>{{event.delivery_count}}</dd>
              <dt>{{i18n
                  "discourse_plunk.admin.detail.identity_conflicts"
                }}</dt>
              <dd>{{event.identity_conflict_count}}</dd>
            </dl>

            <h3>{{i18n "discourse_plunk.admin.detail.provider"}}</h3>
            <dl class="plunk-feedback-admin__grid">
              <dt>{{i18n "discourse_plunk.admin.detail.recipient"}}</dt>
              <dd>{{event.recipient}}</dd>
              <dt>{{i18n
                  "discourse_plunk.admin.detail.contact_subscribed"
                }}</dt>
              <dd>{{show event.contact_subscribed}}</dd>
              <dt>{{i18n "discourse_plunk.admin.detail.plunk_email_id"}}</dt>
              <dd><code>{{show event.plunk_email_id}}</code></dd>
              <dt>{{i18n
                  "discourse_plunk.admin.detail.provider_message_id"
                }}</dt>
              <dd><code>{{show event.provider_message_id}}</code></dd>
              <dt>{{i18n "discourse_plunk.admin.detail.source_type"}}</dt>
              <dd>{{show event.source_type}}</dd>
              <dt>{{i18n "discourse_plunk.admin.detail.classification"}}</dt>
              <dd>{{show event.bounce_classification}}</dd>
              <dt>{{i18n "discourse_plunk.admin.detail.bounce_type"}}</dt>
              <dd>{{show event.bounce_type}}</dd>
              <dt>{{i18n
                  "discourse_plunk.admin.detail.unsubscribe_reason"
                }}</dt>
              <dd>{{show event.unsubscribe_reason}}</dd>
              <dt>{{i18n "discourse_plunk.admin.detail.occurred_at"}}</dt>
              <dd>{{when event.occurred_at}}</dd>
            </dl>

            <h3>{{i18n "discourse_plunk.admin.detail.matching"}}</h3>
            <dl class="plunk-feedback-admin__grid">
              <dt>{{i18n "discourse_plunk.admin.detail.account"}}</dt>
              <dd>
                {{#if event.user_id}}
                  <a href={{userAdminUrl event}}>{{event.username}}</a>
                  (#{{event.user_id}})
                {{else}}
                  —
                {{/if}}
              </dd>
              <dt>{{i18n "discourse_plunk.admin.detail.match_method"}}</dt>
              <dd>{{show event.match_method}}</dd>
              <dt>{{i18n "discourse_plunk.admin.detail.correlation"}}</dt>
              <dd>{{show event.correlation}}</dd>
              <dt>{{i18n "discourse_plunk.admin.detail.email_log"}}</dt>
              <dd>{{show event.email_log_id}}</dd>
              <dt>{{i18n "discourse_plunk.admin.detail.duplicate_of"}}</dt>
              <dd>{{show event.duplicate_of_event_id}}</dd>
            </dl>

            <h3>{{i18n "discourse_plunk.admin.detail.phases"}}</h3>
            <dl class="plunk-feedback-admin__grid">
              <dt>{{i18n "discourse_plunk.admin.detail.preference"}}</dt>
              <dd>{{event.preference_state}}
                {{#if event.preference_applied_at}}
                  ({{when event.preference_applied_at}})
                {{/if}}</dd>
              <dt>{{i18n
                  "discourse_plunk.admin.detail.preference_changes"
                }}</dt>
              <dd>
                {{#each (preferenceChanges event) as |change|}}
                  <div><code>{{change}}</code></div>
                {{else}}
                  {{i18n "discourse_plunk.admin.detail.no_changes"}}
                {{/each}}
              </dd>
              <dt>{{i18n "discourse_plunk.admin.detail.score"}}</dt>
              <dd>{{event.score_state}}
                {{#if event.score_delta}}
                  (+{{event.score_delta}}:
                  {{event.bounce_score_before}}
                  →
                  {{event.bounce_score_after}})
                {{/if}}</dd>
              <dt>{{i18n "discourse_plunk.admin.detail.score_effect"}}</dt>
              <dd>{{show event.score_effect}}</dd>
              <dt>{{i18n
                  "discourse_plunk.admin.detail.correlation_phase"
                }}</dt>
              <dd>{{event.correlation_state}}</dd>
            </dl>

            <h3>{{i18n "discourse_plunk.admin.detail.errors"}}</h3>
            <dl class="plunk-feedback-admin__grid">
              <dt>{{i18n "discourse_plunk.admin.detail.attempts"}}</dt>
              <dd>{{event.attempts}}</dd>
              <dt>{{i18n "discourse_plunk.admin.detail.last_attempt_at"}}</dt>
              <dd>{{when event.last_attempt_at}}</dd>
              <dt>{{i18n "discourse_plunk.admin.detail.next_attempt_at"}}</dt>
              <dd>{{when event.next_attempt_at}}</dd>
              <dt>{{i18n "discourse_plunk.admin.detail.last_error"}}</dt>
              <dd class="plunk-feedback-admin__error">{{show
                  event.last_error
                }}</dd>
            </dl>

            <div class="plunk-feedback-admin__detail-actions">
              {{#if (canReprocess event)}}
                <DButton
                  @label="discourse_plunk.admin.reprocess"
                  @title="discourse_plunk.admin.reprocess_help"
                  @action={{fn @controller.reprocess event.id}}
                  @disabled={{@controller.reprocessing}}
                  class="btn-primary plunk-feedback-admin__reprocess"
                />
              {{/if}}
              <DButton
                @label="discourse_plunk.admin.close"
                @action={{@controller.closeDetail}}
              />
            </div>
          </div>
        {{/let}}
      {{/if}}

      {{#if @controller.events.length}}
        <p>{{i18n "discourse_plunk.admin.total" count=@controller.total}}</p>
        <table class="plunk-feedback-admin__events">
          <thead>
            <tr>
              <th>{{i18n "discourse_plunk.admin.col_id"}}</th>
              <th>{{i18n "discourse_plunk.admin.col_received"}}</th>
              <th>{{i18n "discourse_plunk.admin.col_kind"}}</th>
              <th>{{i18n "discourse_plunk.admin.col_recipient"}}</th>
              <th>{{i18n "discourse_plunk.admin.col_account"}}</th>
              <th>{{i18n "discourse_plunk.admin.col_status"}}</th>
              <th>{{i18n "discourse_plunk.admin.col_outcome"}}</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {{#each @controller.events as |event|}}
              <tr class="plunk-feedback-admin__event">
                <td>{{event.id}}</td>
                <td>{{when event.received_at}}</td>
                <td>{{kindLabel event.kind}}
                  {{#if event.bounce_classification}}
                    ({{event.bounce_classification}})
                  {{/if}}</td>
                <td>{{event.recipient}}</td>
                <td>{{show event.username}}</td>
                <td
                  class="plunk-feedback-admin__status--{{displayStatus event}}"
                >{{statusLabel event}}</td>
                <td>{{show event.outcome}}</td>
                <td>
                  <DButton
                    @label="discourse_plunk.admin.details"
                    @action={{fn @controller.showDetail event.id}}
                    class="btn-small plunk-feedback-admin__show"
                  />
                </td>
              </tr>
            {{/each}}
          </tbody>
        </table>
        <div class="plunk-feedback-admin__pager">
          <DButton
            @label="discourse_plunk.admin.previous_page"
            @action={{@controller.previousPage}}
            @disabled={{if @controller.hasPreviousPage false true}}
            class="btn-small"
          />
          <DButton
            @label="discourse_plunk.admin.next_page"
            @action={{@controller.nextPage}}
            @disabled={{if @controller.hasNextPage false true}}
            class="btn-small"
          />
        </div>
      {{else if @controller.loading}}
        <p>…</p>
      {{else}}
        <p>{{i18n "discourse_plunk.admin.no_events"}}</p>
      {{/if}}
    </section>
  </div>
</template>
