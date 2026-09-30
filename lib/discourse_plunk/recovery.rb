# frozen_string_literal: true

module DiscoursePlunk
  # Finds receipts whose processing did not finish — a phase failed, or the
  # process died between committing the receipt and processing it — and runs
  # them again through the Processor. Bounded: terminal events are never
  # picked up, failed ones stop after FeedbackEvent::MAX_ATTEMPTS, and each
  # sweep takes at most BATCH_SIZE events.
  module Recovery
    BATCH_SIZE = 100
    # A receipt this young may still be in its synchronous webhook request.
    GRACE = 2.minutes
    # Discourse records the time of the last job Sidekiq performed. Core's
    # scheduled jobs run every minute, so a quarter hour of silence means
    # nothing would retry an unfinished receipt.
    HEALTHY_WITHIN = 15.minutes

    def self.healthy?
      last = Jobs.last_job_performed_at
      last.present? && last > HEALTHY_WITHIN.ago
    rescue StandardError
      false
    end

    def self.due
      now = Time.zone.now
      FeedbackEvent
        .retryable
        .where("next_attempt_at IS NULL OR next_attempt_at <= ?", now)
        .where("COALESCE(last_attempt_at, received_at) < ?", now - GRACE)
        .order(:id)
        .limit(BATCH_SIZE)
    end

    def self.sweep
      return 0 if !SiteSetting.plunk_feedback_enabled

      count = 0
      due
        .pluck(:id)
        .each do |id|
          Processor.process(id, trigger: :recovery)
          count += 1
        rescue StandardError => e
          Rails.logger.warn("discourse-plunk: recovery of receipt #{id} failed: #{e.class}")
        end
      count
    end
  end
end
