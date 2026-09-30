# frozen_string_literal: true

module DiscoursePlunk
  # Admin-only. Carries the recipient address and diagnostics; never used for
  # the webhook response or any public/client-visible payload.
  class FeedbackEventSerializer < ApplicationSerializer
    attributes :id,
               :kind,
               :source,
               :status,
               :outcome,
               :recipient,
               :contact_subscribed,
               :workflow_id,
               :workflow_name,
               :execution_id,
               :execution_started_at,
               :plunk_email_id,
               :provider_message_id,
               :bounce_classification,
               :bounce_type,
               :unsubscribe_reason,
               :source_type,
               :occurred_at,
               :received_at,
               :match_method,
               :user_id,
               :username,
               :email_log_id,
               :correlation,
               :duplicate_of_event_id,
               :preference_state,
               :preference_changes,
               :preference_applied_at,
               :score_state,
               :score_effect,
               :score_delta,
               :bounce_score_before,
               :bounce_score_after,
               :score_applied_at,
               :correlation_state,
               :correlation_applied_at,
               :attempts,
               :last_attempt_at,
               :next_attempt_at,
               :last_error,
               :processed_at,
               :delivery_count,
               :last_delivery_at,
               :identity_conflict_count,
               :last_identity_conflict_at

    def username
      object.user&.username
    end
  end
end
