# frozen_string_literal: true

module Jobs
  # Bounds event-history retention (plunk_feedback_event_retention_days),
  # keeping hashed deduplication tombstones.
  class DiscoursePlunkPurgeEvents < ::Jobs::Scheduled
    every 1.day

    def execute(_args)
      DiscoursePlunk::Retention.purge
    end
  end
end
