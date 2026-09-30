# frozen_string_literal: true

module DiscoursePlunk
  # Deletes finished event history older than plunk_feedback_event_retention_days,
  # leaving hashed tombstones behind so deleting history never turns a known
  # old delivery or bounce/complaint into a new one.
  module Retention
    BATCH_SIZE = 500
    PURGEABLE =
      "status IN ('processed', 'unmatched', 'conflict') OR (status = 'failed' AND next_attempt_at IS NULL)"

    def self.purge
      cutoff = SiteSetting.plunk_feedback_event_retention_days.days.ago
      purged = 0

      loop do
        events =
          FeedbackEvent.where("received_at < ?", cutoff).where(PURGEABLE).order(:id).limit(BATCH_SIZE).to_a
        break if events.empty?

        FeedbackEvent.transaction do
          events.each { |event| entomb(event) }
          FeedbackEvent.where(id: events.map(&:id)).delete_all
        end
        purged += events.size
      end

      purged
    end

    def self.entomb(event)
      now = Time.zone.now
      upsert(Tombstone::DELIVERY, event.delivery_digest, event, now)
      upsert(Tombstone::FEEDBACK, event.feedback_digest, event, now) if event.feedback_digest.present?
    end

    def self.upsert(key_type, digest, event, now)
      preference_applied = event.preference_state == "done"
      score_applied = event.score_state == "done"

      DB.exec(<<~SQL, key_type:, digest:, kind: event.kind, preference_applied:, score_applied:, event_id: event.id, received_at: event.received_at, now:)
        INSERT INTO discourse_plunk_tombstones
          (key_type, digest, kind, preference_applied, score_applied, original_event_id,
           original_received_at, created_at, updated_at)
        VALUES
          (:key_type, :digest, :kind, :preference_applied, :score_applied, :event_id,
           :received_at, :now, :now)
        ON CONFLICT (key_type, digest) DO UPDATE SET
          preference_applied = discourse_plunk_tombstones.preference_applied OR EXCLUDED.preference_applied,
          score_applied = discourse_plunk_tombstones.score_applied OR EXCLUDED.score_applied,
          original_event_id = CASE
            WHEN (NOT discourse_plunk_tombstones.preference_applied AND EXCLUDED.preference_applied)
              OR (NOT discourse_plunk_tombstones.score_applied AND EXCLUDED.score_applied)
            THEN EXCLUDED.original_event_id
            ELSE discourse_plunk_tombstones.original_event_id
          END,
          updated_at = EXCLUDED.updated_at
      SQL
    end
  end
end
