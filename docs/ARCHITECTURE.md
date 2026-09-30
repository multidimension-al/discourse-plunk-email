# Architecture and limitations

This note explains how discourse-plunk-email works inside Discourse and
exactly where its guarantees stop. The README covers installation and the
Plunk runbook.

## The shape of it

```
Plunk workflow ──POST──▶ /discourse-plunk/webhooks/{unsubscribe|complaint|bounce}
                              │  WebhooksController (ActionController::Base)
                              │   enabled? secret configured? Bearer secret (constant time)
                              │   no query string, JSON only, ≤ 64 KiB, valid UTF-8
                              ▼
                         Payload.parse(route kind, body)      strict types, bounded strings
                              ▼
                         Receiver.accept                      INSERT … ON CONFLICT DO NOTHING
                              │  unique (kind, workflow_id, execution_id)
                              │  replay → "duplicate"; same ids, other content → 409
                              ▼
                         Processor.process                    DistributedMutex per receipt
                              │ 1. RecipientResolver           user_emails, lower(email)
                              │ 2. MessageCorrelator           EmailLog.message_id + to_address
                              │ 3. preferences   ─ txn ─ lock user_options row, native strategies,
                              │                            verify, marker, staff history
                              │ 4. score         ─ txn ─ lock user_stats row, Email::Receiver
                              │                            .update_bounce_score, marker
                              │ 5. EmailLog      ─ txn ─ bounced = true, marker (bounces only)
                              ▼
                         200 processed · 202 accepted · 5xx (never silently "processed")

Jobs::DiscoursePlunkProcessEvent   retry of one receipt, exponential backoff, 8 attempts
Jobs::DiscoursePlunkRecoverEvents  every 5 min: unfinished receipts (crash, lost retry)
Jobs::DiscoursePlunkPurgeEvents    daily: history past retention → hashed tombstones
Jobs::UserEmail (prepend)          skip queued optional mail for opted-out users
```

Everything that can apply an effect — the webhook, the retry job, the
recovery sweep, the admin "Reprocess" button and the backfill rake task —
calls the same `DiscoursePlunk::Processor`.

## Discourse integration points used (verified at 670dd6be)

| Need | What the plugin uses | Where in core |
|---|---|---|
| Turn off all optional email | `UnsubscribeKey.get_unsubscribe_strategy_for` with an in-memory, never-saved `UnsubscribeKey` of type `digest`, called with `unsubscribe_all` and the "never" digest frequency. That runs `EmailControllerHelper::BaseEmailUnsubscriber#unsubscribe` (email_level and email_messages_level → `:never`, email_digests and mailing_list_mode → false) followed by `DigestEmailUnsubscriber` (digest_after_minutes → the `never` value of `DigestEmailSiteSetting`). | `lib/email_controller_helper/*.rb`, `app/models/unsubscribe_key.rb` |
| Chat summaries | Chat's registered `chat_summary` strategy (`ChatSummaryUnsubscriber`) with `chat_email_frequency: "never"`; direct write of the named enum value when Chat is installed but disabled (its strategy is then unregistered). | `plugins/chat/lib/email_controller_helper/chat_summary_unsubscriber.rb` |
| Policy reminders | discourse-policy's `policy_email` strategy the same way (`policy_email_frequency: "never"`). Both Chat and Policy are enabled on forum.gbfans.com. | `plugins/discourse-policy/lib/email_controller_helper/policy_email_unsubscriber.rb` |
| Postcondition | `UserOption#unsubscribed_from_all?` plus digest frequency, mailing-list column and every installed plugin frequency; the phase fails rather than report success otherwise. | `app/models/user_option.rb` |
| Bounce score | `Email::Receiver.update_bounce_score(email, score)` with `SiteSetting.hard_bounce_score` / `soft_bounce_score`, inside the plugin's transaction. Threshold, `reset_bounce_score_after`, the staff "revoke email" log and the `email_revoked` system message all stay native. | `lib/email/receiver.rb` |
| Message correlation | `EmailLog.message_id` (Discourse's generated Message-ID) and `to_address`, exact match only. | `app/models/email_log.rb`, `lib/email/sender.rb` |
| Staff history | `UserHistory` `custom_staff` / `plunk_feedback_email_opt_out`, acting user = system, target user set, one entry per actual change. | `app/services/staff_action_logger.rb` |
| Queued mail | `Jobs::UserEmail#message_for_email`, prepended via `reloadable_patch` (the mechanism bundled Chat and Policy use for `UserNotifications`). | `app/jobs/regular/user_email.rb` |
| Machine-to-machine route | `ActionController::Base` + `ReadOnlyMixin`, `skip_forgery_protection` on this controller only, as core's own `WebhooksController` does. | `app/controllers/webhooks_controller.rb` |

Not used, deliberately: `WebhooksController#process_bounce` (private,
requires an exact local message match), the inbound-mail parser
(`Email::Receiver#process!`), VERP bounce addresses, SMTP transport changes,
the Plunk API.

## Idempotency model

- **Delivery identity** — `(kind, workflow_id, execution_id)`, enforced by a
  unique index. A replay adds to `delivery_count`; the same identity with a
  different recipient/message/classification is a 409 conflict and is
  counted on the original receipt.
- **Feedback identity** — for complaints and bounces:
  SHA-256 of kind, recipient, Plunk `emailId` (else provider `messageId`)
  and bounce classification. A second execution carrying the same feedback
  is kept as its own receipt but skips both effects (`duplicate_feedback`).
  Soft-then-hard for the same message are two identities, so the hard bounce
  still scores. Feedback without any stable identifier is never merged.
  Unsubscribes have no feedback identity: each `contact.unsubscribed` is a
  distinct opt-out; they never add bounce score.
- **Phase markers** — each effect commits in the same transaction as its
  `done` marker, under a row lock on the user's `user_options` or
  `user_stats` row. A completed phase is never run again, so neither a
  replay, a retry, a recovery sweep nor an admin reprocess can re-apply it —
  including after the user opts back in.
- **Tombstones** — the retention job replaces old receipts with hashed
  delivery and feedback digests, so a very late replay stays a duplicate.

## Failure handling

The preference phase commits first. If scoring or EmailLog bookkeeping then
fails, the receipt is `failed` with `next_attempt_at` set, a retry job is
enqueued (after the per-receipt mutex is released), and the webhook answers
**202 accepted** — but only when Sidekiq has performed a job in the last 15
minutes (`Jobs.last_job_performed_at`); otherwise **503**, so Plunk's
execution log shows the problem. Retries back off 1, 5, 15, 60, 180, 360,
720 minutes and stop after 8 attempts (`retries_exhausted`, visible in the
admin page, reprocessable by an administrator). Receipts that never started
processing are picked up by the recovery sweep after two minutes.

Unknown, ambiguous, non-human and conflicting recipients are terminal
(`unmatched` / `conflict`): recorded, never retried, and their effects are
left `blocked` so that an administrator's explicit reprocess (for example
after adding the address to the right account) can still apply them.

## Limitations — stated precisely

1. **Critical and account email is still sent.** The plugin disables
   optional preferences only. Core's `EmailLog::CRITICAL_EMAIL_TYPES`
   (signup, activation, forgot_password, admin_login, email-change
   confirmations and notices) bypass the bounce-score threshold, and account
   notices such as suspension or silencing are not preference-controlled.
   This is intentional: users must be able to recover their accounts. It is
   not a universal SMTP block.
2. **Mail already handed to Plunk cannot be recalled.** Changing Discourse
   preferences affects only mail Discourse has not yet sent.
3. **Queued mail coverage.** Reply/mention/quote/link/watching/group/
   post-approved/invite notifications, private-message notifications and
   Policy reminders queued before the feedback are skipped by the
   `Jobs::UserEmail` re-check. Digests, mailing-list mode and Chat summaries
   re-read their preferences at send time in core. A job that is already
   executing when the preference commits can still complete. Other plugins'
   custom mail types are not re-checked.
4. **Message correlation will usually be `user_matched_message_unmatched`.**
   Plunk's `messageId` is the provider's (SES) id and `emailId` is Plunk's own;
   Discourse records its RFC Message-ID. Unless the two ever coincide exactly,
   EmailLogs are not marked bounced. Account-level effects do not depend on
   this. Plunk supplies no SMTP diagnostic, so `bounce_error_code` is never
   set.
5. **Plunk does not retry failed webhooks.** A request blocked before it
   reaches Discourse (DNS, proxy, Cloudflare challenge, 429 from Discourse's
   global per-IP limit) leaves no receipt here; only Plunk's workflow
   execution history shows it. Discourse's global limits (default 50
   requests / 10 s and 200 / minute per IP) apply to these routes.
6. **Project-wide opt-out.** A `contact.unsubscribed` from the GBFans Plunk
   project — including a Plunk "snooze" — turns off *all* optional forum
   email. The payload cannot prove a narrower preference, so none is
   inferred. Plunk's own `snooze_expired` resubscribe is not mirrored.
7. **No reverse synchronisation.** Opting back in on Discourse does not
   resubscribe the Plunk contact, and later Plunk subscribe/delivery/open
   events do not re-enable Discourse email.
8. **All bounces opt out (owner policy).** Plunk itself unsubscribes only on
   permanent bounces and complaints; this plugin turns optional email off on
   every accepted bounce, including transient and undetermined ones, while
   scoring them as soft.
9. **Core's revoke-email log includes the address.** When the native bounce
   threshold is crossed, core writes the address into the staff "revoke
   email" entry (visible to moderators). The plugin's own staff entries never
   include it.
10. **Logging.** Plunk payload keys and the two secret settings are filtered
    from Rails parameter logging. ActiveRecord's DEBUG-level SQL echo (off in
    production) would still show addresses, as it does for every core query.
    Rails parses the JSON body for its request log before the controller's
    64 KiB check; the outer bound is nginx's `client_max_body_size` (10 MB in
    Discourse's template).
11. **Bot accounts are ignored**, staged accounts are treated like any other
    account, and an unactivated account's primary address is matched and
    recorded as `primary_email_unactivated`.
