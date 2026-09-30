# Changelog

## 1.0.0

- Receive Plunk `contact.unsubscribed`, `email.complaint` and `email.bounce`
  workflow webhooks on three authenticated routes.
- Turn off every optional email preference through Discourse's native
  unsubscribe strategies (core, Chat, Policy) and apply native bounce scoring.
- Durable, idempotent event ledger with retries, recovery, retention
  tombstones, admin diagnostics and reprocessing, and a backfill rake task.
