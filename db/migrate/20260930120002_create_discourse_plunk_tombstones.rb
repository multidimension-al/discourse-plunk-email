# frozen_string_literal: true

# Compact deduplication records that outlive the verbose event history.
# When the retention job deletes an old event it leaves a tombstone keyed by
# a SHA-256 digest (no address or identifier in the clear), so a very late
# replay of that delivery, or the same bounce/complaint arriving through a
# new execution, is still recognised and never becomes a fresh opt-out or a
# second bounce-score increment.
class CreateDiscoursePlunkTombstones < ActiveRecord::Migration[8.0]
  def change
    create_table :discourse_plunk_tombstones do |t|
      t.string :key_type, null: false, limit: 16
      t.string :digest, null: false, limit: 64
      t.string :kind, null: false, limit: 32
      t.boolean :preference_applied, null: false, default: false
      t.boolean :score_applied, null: false, default: false
      t.bigint :original_event_id
      t.datetime :original_received_at
      t.timestamps
    end

    add_index :discourse_plunk_tombstones,
              %i[key_type digest],
              unique: true,
              name: "idx_discourse_plunk_tombstones_key"
  end
end
