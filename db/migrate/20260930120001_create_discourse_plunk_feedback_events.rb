# frozen_string_literal: true

# The plugin's event ledger: one row per authenticated, schema-valid Plunk
# delivery. It records processing state and audit detail only. Native
# user_options remain the authoritative subscription state.
class CreateDiscoursePlunkFeedbackEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :discourse_plunk_feedback_events do |t|
      # What arrived
      t.string :kind, null: false, limit: 32
      t.string :source, null: false, limit: 16, default: "webhook"
      t.string :workflow_id, null: false, limit: 191
      t.string :workflow_name, limit: 191
      t.string :execution_id, null: false, limit: 191
      t.datetime :execution_started_at
      t.string :recipient, null: false, limit: 320
      t.boolean :contact_subscribed
      t.string :plunk_email_id, limit: 191
      t.string :provider_message_id, limit: 512
      t.string :bounce_classification, limit: 16
      t.string :bounce_type, limit: 64
      t.string :unsubscribe_reason, limit: 64
      t.string :source_type, limit: 32
      t.datetime :occurred_at
      t.datetime :received_at, null: false

      # Identities used for deduplication
      t.string :delivery_digest, null: false, limit: 64
      t.string :identity_digest, null: false, limit: 64
      t.string :feedback_digest, limit: 64

      # Outcome
      t.string :status, null: false, limit: 24, default: "received"
      t.string :outcome, limit: 48
      t.integer :user_id
      t.string :match_method, limit: 24
      t.integer :email_log_id
      t.string :correlation, limit: 48
      t.bigint :duplicate_of_event_id

      # Phases
      t.string :preference_state, null: false, limit: 16, default: "pending"
      t.jsonb :preference_changes, null: false, default: {}
      t.datetime :preference_applied_at
      t.string :score_state, null: false, limit: 16, default: "pending"
      t.string :score_effect, limit: 32
      t.integer :score_delta
      t.integer :bounce_score_before
      t.integer :bounce_score_after
      t.datetime :score_applied_at
      t.string :correlation_state, null: false, limit: 16, default: "pending"
      t.datetime :correlation_applied_at

      # Attempts
      t.integer :attempts, null: false, default: 0
      t.datetime :last_attempt_at
      t.datetime :next_attempt_at
      t.string :last_error, limit: 1000
      t.datetime :processed_at

      # Replays of this exact delivery, and deliveries that reused its identity
      # with different content.
      t.integer :delivery_count, null: false, default: 1
      t.datetime :last_delivery_at
      t.integer :identity_conflict_count, null: false, default: 0
      t.datetime :last_identity_conflict_at

      t.timestamps
    end

    add_index :discourse_plunk_feedback_events,
              %i[kind workflow_id execution_id],
              unique: true,
              name: "idx_discourse_plunk_events_delivery"
    add_index :discourse_plunk_feedback_events, :feedback_digest
    add_index :discourse_plunk_feedback_events, :recipient
    add_index :discourse_plunk_feedback_events, :user_id
    add_index :discourse_plunk_feedback_events, %i[status next_attempt_at]
    add_index :discourse_plunk_feedback_events, :received_at
  end
end
