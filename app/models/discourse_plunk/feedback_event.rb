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

    # pending         not run yet
    # done            the effect was applied (its marker committed with it)
    # skipped         deliberately not applied: duplicate feedback, zero score
    # not_applicable  never applies to this kind of event
    # failed          raised; retried with backoff
    # blocked         not run because no single current owner of the address
    #                 was found; only an administrator reprocess runs it again
    PHASE_STATES = %w[pending done skipped not_applicable failed blocked].freeze
    PHASE_FINISHED = %w[done skipped not_applicable].freeze

    MAX_ATTEMPTS = 8
    BACKOFF = [1, 5, 15, 60, 180, 360, 720].map(&:minutes).freeze

    belongs_to :user, optional: true
    belongs_to :email_log, optional: true

    validates :kind, inclusion: { in: KINDS }
    validates :status, inclusion: { in: STATUSES }

    scope :retryable,
          -> { where(status: %w[received processing failed]).where("attempts < ?", MAX_ATTEMPTS) }

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

# == Schema Information
#
# Table name: discourse_plunk_feedback_events
#
#  id                        :bigint           not null, primary key
#  attempts                  :integer          default(0), not null
#  bounce_classification     :string(16)
#  bounce_score_after        :integer
#  bounce_score_before       :integer
#  bounce_type               :string(64)
#  contact_subscribed        :boolean
#  correlation               :string(48)
#  correlation_applied_at    :datetime
#  correlation_state         :string(16)       default("pending"), not null
#  delivery_count            :integer          default(1), not null
#  delivery_digest           :string(64)       not null
#  execution_started_at      :datetime
#  feedback_digest           :string(64)
#  identity_conflict_count   :integer          default(0), not null
#  identity_digest           :string(64)       not null
#  kind                      :string(32)       not null
#  last_attempt_at           :datetime
#  last_delivery_at          :datetime
#  last_error                :string(1000)
#  last_identity_conflict_at :datetime
#  match_method              :string(32)
#  next_attempt_at           :datetime
#  occurred_at               :datetime
#  outcome                   :string(48)
#  preference_applied_at     :datetime
#  preference_changes        :jsonb            not null
#  preference_state          :string(16)       default("pending"), not null
#  processed_at              :datetime
#  received_at               :datetime         not null
#  recipient                 :string(320)      not null
#  score_applied_at          :datetime
#  score_delta               :integer
#  score_effect              :string(32)
#  score_state               :string(16)       default("pending"), not null
#  source                    :string(16)       default("webhook"), not null
#  source_type               :string(32)
#  status                    :string(24)       default("received"), not null
#  unsubscribe_reason        :string(64)
#  workflow_name             :string(191)
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  duplicate_of_event_id     :bigint
#  email_log_id              :integer
#  execution_id              :string(191)      not null
#  plunk_email_id            :string(191)
#  provider_message_id       :string(512)
#  user_id                   :integer
#  workflow_id               :string(191)      not null
#
# Indexes
#
#  idx_discourse_plunk_events_delivery                       (kind,workflow_id,execution_id) UNIQUE
#  idx_on_status_next_attempt_at_bcf38b8d81                  (status,next_attempt_at)
#  index_discourse_plunk_feedback_events_on_feedback_digest  (feedback_digest)
#  index_discourse_plunk_feedback_events_on_received_at      (received_at)
#  index_discourse_plunk_feedback_events_on_recipient        (recipient)
#  index_discourse_plunk_feedback_events_on_user_id          (user_id)
#
