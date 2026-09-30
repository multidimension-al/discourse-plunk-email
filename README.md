# discourse-plunk-email

Receives Plunk **unsubscribe**, **spam complaint** and **bounce** feedback
over authenticated HTTPS webhooks and applies it to Discourse the native
way: every optional email preference of the matching account is turned off
through Discourse's own unsubscribe strategies, complaints and bounces feed
Discourse's native bounce score, and every delivery is recorded in an audit
ledger administrators can search and reprocess.

It only *receives*. Outbound mail keeps going through Plunk's SMTP service
exactly as before. The plugin needs no Plunk API key, never calls Plunk, and
does not touch SMTP settings.

- [What it does](#what-it-does)
- [Tested version](#tested-version)
- [Install](#install)
- [Configure Discourse](#configure-discourse)
- [Set up the three Plunk workflows](#set-up-the-three-plunk-workflows)
- [Reverse proxy and Cloudflare](#reverse-proxy-and-cloudflare)
- [Test on staging or a test account](#test-on-staging-or-a-test-account)
- [Monitoring and diagnostics](#monitoring-and-diagnostics)
- [Retrying safely](#retrying-safely)
- [Rotating the secret](#rotating-the-secret)
- [Backfilling historical feedback](#backfilling-historical-feedback)
- [Rollback and uninstall](#rollback-and-uninstall)
- [Data kept](#data-kept)
- [Limitations](#limitations)
- [Development and tests](#development-and-tests)

Architecture and the precise limitations are in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## What it does

| Plunk event | Route | Optional-email preferences | Native bounce score |
|---|---|---|---|
| `contact.unsubscribed` | `/discourse-plunk/webhooks/unsubscribe` | all off | none, whatever `reason` Plunk gives (`bounce`, `complaint`, `snooze`) |
| `email.complaint` | `/discourse-plunk/webhooks/complaint` | all off | `hard_bounce_score` once (core's Postmark handler scores complaints the same way); recorded as a complaint |
| `email.bounce`, `bounceType: Permanent` | `/discourse-plunk/webhooks/bounce` | all off | `hard_bounce_score` once |
| `email.bounce`, `bounceType: Transient` | same | all off | `soft_bounce_score` once; recorded as transient |
| `email.bounce`, `Undetermined`, missing or anything else | same | all off | `soft_bounce_score` once; recorded as `unknown` — never promoted to permanent, no SMTP code invented |

Turning a *temporary* bounce into a full opt-out is this forum's policy, not
a claim that the bounce is permanent; the real classification is kept in the
ledger and in the score used. (Plunk itself only unsubscribes a contact on a
permanent bounce or a complaint.)

"All off" means, for the matched account:

- `email_level` and `email_messages_level` → **never**, `email_digests` and
  `mailing_list_mode` → **off** (core's unsubscribe-all, so
  `user_option.unsubscribed_from_all?` is true),
- `digest_after_minutes` → the **never** digest frequency, so the preferences
  page shows a coherent value,
- `chat_email_frequency` → **never** (bundled Chat) and
  `policy_email_frequency` → **never** (discourse-policy) when installed —
  both are enabled on forum.gbfans.com.

Nothing else changes: in-app and push notifications, watched topics and
categories, bookmarks, groups, trust level, account status and login all stay
as they were. Password reset, activation, admin-login and email-change mail
still go out (see [Limitations](#limitations)). The plugin never sends a
confirmation email.

Each actual preference change is written to **staff history** (custom type
`plunk_feedback_email_opt_out`, acting user `system`, without the address).
Replays do not add entries.

Matching uses the address exactly as Discourse stores it (trimmed,
lower-cased) against the account's primary or confirmed secondary addresses —
no plus-tag or dot stripping. Unknown, ambiguous or conflicting recipients are
logged and left alone. Nothing is ever re-enabled automatically.

## Tested version

Tested against the version forum.gbfans.com reported on 30 September 2026
(`<meta name="generator">`): **Discourse 2026.9.0-latest, commit
[`670dd6be75cb9f378330151ccd60d348ab2b589b`](https://github.com/discourse/discourse/commit/670dd6be75cb9f378330151ccd60d348ab2b589b)**,
with every bundled plugin loaded (`LOAD_PLUGINS=1`, including Chat and
discourse-policy). Local environment: Ruby 3.4.9, PostgreSQL 16.15 with
pgvector 0.8.1, Redis 7.0.15, Node 22.22.2. Other Discourse versions have not
been tested; `required_version` is set to `2026.9.0-latest`.

Plunk's payload contract was checked against Plunk's documentation and source
(`useplunk/plunk`, `WorkflowExecutionService#executeWebhook` and the SNS
feedback handler) on the same date.

## Install

On the Discourse host, add the plugin to `containers/app.yml`:

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/multidimension-al/discourse-plunk-email.git
```

then rebuild:

```sh
cd /var/discourse
./launcher rebuild app
```

The rebuild runs the plugin's migrations (two new tables,
`discourse_plunk_feedback_events` and `discourse_plunk_tombstones`). The
plugin starts **disabled and unconfigured**; until you finish the next section
every webhook request is refused.

## Configure Discourse

1. Generate an independent secret of at least 32 random bytes on a trusted
   machine. Do not reuse an admin API key or the SMTP password (the setting
   rejects both):

   ```sh
   openssl rand -base64 48
   ```

   Keep it in your password manager; Discourse will not show it again.
2. **Admin → Plugins → Plunk feedback → Settings**
   - `plunk feedback webhook secret`: paste the secret.
   - `plunk feedback enabled`: check.
   - `plunk feedback event retention days`: 365 by default.
3. Open the **Feedback events** tab. It shows the three absolute webhook URLs
   with copy buttons (built from the forum's public base URL, including any
   subfolder), whether the secret is configured (never the secret itself),
   and whether the retry worker is running.

For forum.gbfans.com the URLs are:

```
https://forum.gbfans.com/discourse-plunk/webhooks/unsubscribe
https://forum.gbfans.com/discourse-plunk/webhooks/complaint
https://forum.gbfans.com/discourse-plunk/webhooks/bounce
```

## Set up the three Plunk workflows

Create these **in the GBFans Plunk project only** — the project, and the
workflows you create in it, decide which feedback reaches the forum. A
`contact.unsubscribed` anywhere in that project becomes a forum-wide
optional-email opt-out.

In the Plunk dashboard, **Workflows → New workflow**, three times:

| Workflow name (suggested) | Trigger (event) | Webhook step URL |
|---|---|---|
| Discourse unsubscribe feedback | `contact.unsubscribed` | `https://forum.gbfans.com/discourse-plunk/webhooks/unsubscribe` |
| Discourse complaint feedback | `email.complaint` | `https://forum.gbfans.com/discourse-plunk/webhooks/complaint` |
| Discourse bounce feedback | `email.bounce` | `https://forum.gbfans.com/discourse-plunk/webhooks/bounce` |

For each workflow:

1. **Trigger**: *Event*, choose the event from the table.
2. Add one **Webhook** step:
   - **URL**: the matching URL from the table (copy it from the admin page).
   - **Method**: `POST`.
   - **Headers**:

     ```json
     {
       "Authorization": "Bearer REPLACE_WITH_PLUGIN_WEBHOOK_SECRET"
     }
     ```

   - **Body**: leave **blank**. Plunk then sends its default payload
     (`contact`, `workflow`, `execution`, `event`), which is exactly what the
     plugin validates. Do not add a custom body or template variables.
3. Save and **enable** the workflow.

One workflow per trigger: a second workflow on the same trigger delivers the
same feedback twice (the plugin recognises repeats by Plunk's `emailId`, but
feedback without an id cannot be de-duplicated). Do not put conditions in
front of the webhook step — filtering is done by the plugin.

**Where failures show up.** Plunk does not retry a failed webhook step and
times out after 10 seconds. After enabling, and whenever the admin page's
*Last delivery* looks stale, open each workflow's execution history in Plunk
and look at the Webhook step's recorded **status code and response body**
(not only the execution's overall state). The plugin always answers JSON:

| Status | Body `status` | Meaning |
|---|---|---|
| 200 | `processed` | done (including "no forum account has this address") |
| 200 | `duplicate` | a replay of a delivery already handled |
| 202 | `accepted` | stored; an unfinished step will be retried automatically |
| 400 / 413 / 415 / 422 | `rejected` | malformed request (`details` lists schema errors); nothing stored |
| 401 | `rejected` | wrong or missing `Authorization` header |
| 405 | `rejected` | not a POST |
| 409 | `conflict` | the same workflow/execution ids arrived with different content |
| 503 | `rejected` | receiver disabled, secret not configured, or forum read-only |
| 500 / 503 | `failed` | could not process or safely accept — investigate |

An HTML page, a redirect or a Cloudflare challenge in that response means the
request never reached the plugin (next section).

## Reverse proxy and Cloudflare

Use the public HTTPS forum URL, never the origin hostname or IP. The three
exact paths must:

- accept `POST` with `Content-Type: application/json`,
- pass the `Authorization` header through unchanged (Discourse's bundled
  nginx does),
- never redirect (not to a login page, not to `www`, not to another scheme),
- never answer with an interactive or JavaScript bot challenge.

The route works without a browser session even with `login required` on;
nothing about forum login needs to change.

With Cloudflare in front, scope any exception to these paths only — for
example a WAF custom rule with action *Skip* for

```
(http.request.method eq "POST" and http.request.uri.path in {"/discourse-plunk/webhooks/unsubscribe" "/discourse-plunk/webhooks/complaint" "/discourse-plunk/webhooks/bounce"})
```

Do not relax protection for the whole forum. Some Cloudflare bot features
cannot be exempted per path on every plan; whatever the configuration, verify
it with the curl test below **from a machine outside your network** and with
a test execution from Plunk.

Discourse's own global per-IP limits (defaults: 50 requests per 10 seconds,
200 per minute) apply to these routes. The plugin adds no lower limit. A
burst beyond that would get HTTP 429, which Plunk shows in the step result
and does not retry.

## Test on staging or a test account

Use a staging forum, or on production a **designated test account** whose
email preferences you can reset. Never send a real spam complaint to test.
The synthetic fixtures in `spec/fixtures/plunk/` (all addresses and ids are
made up) are the request bodies; run these commands from a checkout of this
repository, with `curl` 7.55 or later and `jq`.

```sh
FORUM=https://staging.example.com      # or the production forum, test account only
TEST_ADDRESS=your-test-account@example.com

# Keep the secret out of the command line and shell history.
umask 077
printf 'Authorization: Bearer %s\n' "$(cat ~/plunk-webhook-secret)" > ~/plunk-auth.header

# A fresh execution id each time, addressed to the test account.
jq --arg email "$TEST_ADDRESS" --arg exec "manual-$(date +%s)" \
   '.contact.email = $email | .execution.id = $exec' \
   spec/fixtures/plunk/synthetic-contact-unsubscribed.json > /tmp/plunk-unsubscribe.json

curl -sS -i -X POST "$FORUM/discourse-plunk/webhooks/unsubscribe" \
  -H @"$HOME/plunk-auth.header" -H "Content-Type: application/json" \
  --data-binary @/tmp/plunk-unsubscribe.json
```

Expect a 200 response with `{"status":"processed","receipt_id":…}`, then check
the test account's **Preferences → Emails** and the event on the admin page.
Posting the same file again returns `"duplicate"`.

Negative checks (expect 401 and 405 respectively, and nothing recorded):

```sh
curl -sS -i -X POST "$FORUM/discourse-plunk/webhooks/unsubscribe" \
  -H "Authorization: Bearer wrong" -H "Content-Type: application/json" \
  --data-binary @/tmp/plunk-unsubscribe.json
curl -sS -i "$FORUM/discourse-plunk/webhooks/unsubscribe"
```

The complaint and bounce fixtures also add bounce score. Afterwards, restore
the test account: *Admin → Users → the account → reset bounce score*, and
re-enable its email preferences on its preferences page. The plugin will not
undo either of those.

To test the whole path from Plunk, point a copy of one workflow at staging,
trigger its event for a test contact in a Plunk project that is not the
production one, and confirm the step result is 200.

## Monitoring and diagnostics

**Admin → Plugins → Plunk feedback → Feedback events** (administrators only):

- configuration state, retry-worker health, the webhook URLs;
- last delivery / last processed time, and counts of pending, retrying,
  failed, unmatched, conflicting and processed events, plus deliveries that
  reused an id with different content;
- a searchable list (address fragment, username, receipt `#id`, workflow,
  execution, Plunk email id or provider message id; filter by status and
  event);
- per-event detail: original event type, normalised recipient, matched
  account and how, message correlation, workflow/execution ids, Plunk and
  provider ids, classification and reason, the workflow start time (shown
  separately from the provider's event time), each phase's state, the
  before → after of every changed preference, the score effect, attempts and
  the sanitised last error.

Statuses: `processed`, `unmatched` (no account owns the address — nothing
changed, never retried), `conflict` (ambiguous owner, the message belongs to
another account, or the address changed hands mid-retry — nothing
cross-applied, never retried), `failed` (retrying, or retries exhausted),
`received`/`processing` (in flight).

Outcomes: `applied`, `already_unsubscribed`, `duplicate_feedback`,
`unknown_recipient`, `non_human_account`, `ambiguous_recipient`,
`message_user_conflict`, `recipient_owner_changed`, `retry_scheduled`,
`retries_exhausted`.

Message correlation: `message_matched` (an EmailLog with exactly that
Message-ID and recipient), `user_matched_message_unmatched`,
`no_message_identifier`, `message_ambiguous`, `message_user_conflict`,
`lookup_failed`. Expect mostly `user_matched_message_unmatched`: Plunk's
message id is its provider's, not the Message-ID Discourse records. That does
not affect the account-level effects.

Queued notification emails skipped because of an opt-out appear in
**Admin → Email → Skipped** with the reason "Not sent: the recipient's …
preference is off after Plunk feedback."

## Retrying safely

Failed phases retry automatically (1, 5, 15, 60, 180, 360, 720 minutes; eight
attempts), and a recovery job every five minutes picks up anything left
unfinished by a crash or restart. To retry by hand, open the event and click
**Reprocess**, or from the container:

```sh
cd /var/discourse && ./launcher enter app
rake 'plunk_feedback:reprocess[123]'
```

Both run the same idempotent service. Completed phases are never repeated, so
reprocessing can never re-apply an opt-out the user has since reversed, or add
bounce score twice. Reprocessing an `unmatched` or `conflict` event resolves
the address again — use it after deliberately fixing the account.

## Rotating the secret

Planned rotation, without dropping events:

1. Generate a new secret (`openssl rand -base64 48`).
2. Put the **current** secret into `plunk feedback webhook previous secret`
   (from your password manager, or in the container:
   `rails r 'SiteSetting.plunk_feedback_webhook_previous_secret = SiteSetting.plunk_feedback_webhook_secret'`).
3. Put the new secret into `plunk feedback webhook secret`. Both are accepted
   now.
4. Update the `Authorization` header in all three Plunk webhook steps.
5. Confirm new deliveries succeed (admin page, Plunk step results).
6. Clear `plunk feedback webhook previous secret`.

If the secret leaked, skip step 2: the old secret stops working at once, and
deliveries fail visibly in Plunk until step 4 is done. Anything missed in
between can be [backfilled](#backfilling-historical-feedback). An empty
setting never authenticates anything.

## Backfilling historical feedback

New webhooks do not repair complaints and bounces that happened before the
workflows existed. To apply known historical feedback deliberately, put the
records in a JSON file on the host (for example
`/var/discourse/shared/standalone/plunk-complaints.json`, which is `/shared/…`
inside the container) — one Plunk default-body payload or an array of them,
**one file per event type**, each record with a unique `workflow.id` /
`execution.id` pair:

```json
[
  {
    "contact": { "email": "member@example.com", "subscribed": false },
    "workflow": { "id": "backfill-2026-09", "name": "Manual backfill" },
    "execution": { "id": "backfill-2026-09-0001" },
    "event": { "emailId": "the-plunk-email-id-if-known", "complainedAt": "2026-08-14T09:12:00.000Z" }
  }
]
```

Include Plunk's `emailId` when you have it: a later live callback for the same
email is then recognised as the same complaint. For bounces add `bounceType`
(`Permanent`, `Transient` or `Undetermined`). Then:

```sh
cd /var/discourse && ./launcher enter app
rake 'plunk_feedback:replay[complaint,/shared/plunk-complaints.json]'
```

Each record goes through the same validation, ledger and processor as a live
webhook (marked `source: backfill`), and the task prints one line per record
(`processed`, `duplicate`, `unmatched`, `conflict` or `invalid` with the
schema errors). Running the same file twice is safe. Nothing is fetched from
Plunk.

## Rollback and uninstall

- **Stop receiving**: disable the three Plunk workflows first, then uncheck
  `plunk feedback enabled`. The URLs then answer 503, retries and recovery
  stop, the queued-mail re-check stops, and the admin page stays readable.
- **Uninstall**: remove the `git clone` line from `app.yml` and
  `./launcher rebuild app`. The two plugin tables stay behind, unused; drop
  them only if you are sure:
  `DROP TABLE discourse_plunk_feedback_events, discourse_plunk_tombstones;`
  and delete their two rows from `schema_migrations`.

Neither disabling nor uninstalling restores anyone's old email preferences or
bounce score. Those are ordinary Discourse settings, owned by the users (and
administrators) from the moment they were changed.

## Data kept

Per delivery: the event type, normalised recipient, workflow and execution
ids and workflow name, Plunk email id, provider message id, bounce
classification and raw `bounceType`, unsubscribe reason, Plunk `sourceType`,
provider event time, workflow start time, the `contact.subscribed` snapshot,
and the processing record. Subjects, sender addresses, `contact.data` and any
other payload fields are dropped on arrival. Finished events older than
`plunk feedback event retention days` are deleted daily; SHA-256 tombstones
(no address or identifier in the clear) are kept so an old delivery can never
come back as new. The recipient and all diagnostics are visible to
administrators only; moderators see only the address-free staff-history
entries. The request body and the secret settings are filtered from Rails'
parameter logging.

## Limitations

The full list is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#limitations--stated-precisely).
In short:

- It disables **optional** forum email. Account-recovery and security mail
  (signup/activation, password reset, admin login, email-change
  confirmations) is still sent, even over the bounce threshold, as core
  intends. This is not a universal SMTP block.
- Mail already handed to Plunk cannot be recalled. Queued notification, PM
  and Policy mail is re-checked; a job already executing may still finish.
- Plunk does not retry failed webhooks; requests blocked before Discourse
  leave no trace here, only in Plunk's execution history.
- Message-level correlation rarely matches (different message ids); account
  effects never depend on it.
- A project-level unsubscribe (including a Plunk snooze) is a forum-wide
  opt-out; there is no reverse sync in either direction.
- When the native bounce threshold is crossed, core's own "revoke email"
  staff entry includes the address.

## Development and tests

From a Discourse checkout at the tested commit, with this repository at
`plugins/discourse-plunk-email`:

```sh
LOAD_PLUGINS=1 RAILS_ENV=test bin/rake db:create db:migrate
LOAD_PLUGINS=1 bin/rspec plugins/discourse-plunk-email/spec

# the admin-page system specs also need the frontend and plugin JS built
bin/ember-cli --build
LOAD_PLUGINS=1 bin/rake assets:precompile:build_plugins
LOAD_PLUGINS=1 bin/rspec plugins/discourse-plunk-email/spec/system

# lint (from the plugin directory)
bundle exec rubocop
bundle exec stree check Gemfile $(git ls-files '*.rb' '*.rake')
pnpm install && pnpm lint
```

Result on 30 September 2026 against commit `670dd6be75`: **161 examples, 0
failures** (40 webhook request, 12 admin API, 50 processor, 13 payload, 12
secret validator, 5 backfill/rollback, 4 retention, 19 email-path
integration, 3 real-thread concurrency, 3 admin-page system specs); rubocop,
syntax_tree, eslint and prettier clean. Every spec runs against real
Discourse models, jobs, mailers and the database; mail goes to the test
delivery method only, outbound HTTP is blocked by WebMock (and asserted
unused), and no Plunk API is called.

What the suite covers: authentication, disabled/unconfigured/read-only,
login-required forums, CSRF kept elsewhere, method/content-type/size/UTF-8/
schema validation, all fixtures, sparse metadata, every row of the policy
table with the full preference postcondition, Chat enabled/disabled/absent,
Policy, already-unsubscribed users, secondary, removed and changed addresses,
unknown/bot/ambiguous/conflicting recipients, exact vs no message match,
replays, concurrent duplicates, cross-execution duplicates, unsubscribe and
complaint in both orders and concurrently, distinct messages, soft-to-hard,
failure after the preference commit, score rollback and retry, restart
recovery, retries exhausted, admin reprocess, replay after an explicit
opt-in, retention tombstones, backfill, the real digest / reply notification
/ PM notification / mailing-list / Chat summary / Policy paths before and
after feedback, mail queued before feedback, in-app notifications and watch
levels preserved, account-recovery mail still sent, the native bounce
threshold's single revoke log and system message with no email to the
recipient, secret and address absence from responses and logs.

Local environment notes, for honesty about what ran where: the GitHub Actions
workflow (Discourse's shared plugin CI) is included but runs on pull requests
and `main`, so it had not run when this was written. The system specs ran on
the test machine's pre-installed Chromium 141 rather than the Chromium 151
that Discourse's Playwright 1.62.1 downloads, and with a `magick` →
ImageMagick 6 shim for core's letter avatars. Neither affects the plugin's
code.
