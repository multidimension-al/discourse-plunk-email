# frozen_string_literal: true

module DiscoursePlunk
  class FeedbackEvent < ActiveRecord::Base
    self.table_name = "discourse_plunk_feedback_events"

    KINDS = DiscoursePlunk::ROUTES.values.freeze
    UNSUBSCRIBE = "contact.unsubscribed"
    COMPLAINT = "email.complaint"
    BOUNCE = "email.bounce"

    # received    durable receipt, processing not started (or interrupted)
    # processing  a processor currently holds the event
    # processed   every phase finished
    # failed      a phase raised; retried with backoff until attempts run out
    # unmatched   no Discourse account owns the recipient (terminal, no retry)
    # conflict    ambiguous or contradictory ownership (terminal, no retry)
    STATUSES = %w[received processing processed failed unmatched conflict].freeze
    TERMINAL_STATUSES = %w[processed unmatched conflict].freeze

    # pending → done | skipped | not_applicable | failed
    PHASE_STATES = %w[pending done skipped not_applicable failed].freeze
    PHASE_FINISHED = %w[done skipped not_applicable].freeze

    MAX_ATTEMPTS = 8
    BACKOFF = [1, 5, 15, 60, 180, 360, 720].map(&:minutes).freeze

    belongs_to :user, optional: true
    belongs_to :email_log, optional: true

    validates :kind, inclusion: { in: KINDS }
    validates :status, inclusion: { in: STATUSES }

    scope :retryable,
          -> do
            where(status: %w[received processing failed]).where(
              "attempts < ?",
              MAX_ATTEMPTS,
            )
          end

    def unsubscribe?
      kind == UNSUBSCRIBE
    end

    def complaint?
      kind == COMPLAINT
    end

    def bounce?
      kind == BOUNCE
    end

    def terminal?
      TERMINAL_STATUSES.include?(status) || (status == "failed" && next_attempt_at.nil?)
    end

    def phases_finished?
      PHASE_FINISHED.include?(preference_state) && PHASE_FINISHED.include?(score_state) &&
        PHASE_FINISHED.include?(correlation_state)
    end

    def self.backoff_for(attempts)
      BACKOFF[[attempts - 1, 0].max] || BACKOFF.last
    end
  end
end
