# frozen_string_literal: true

module DiscoursePlunk
  class Tombstone < ActiveRecord::Base
    self.table_name = "discourse_plunk_tombstones"

    DELIVERY = "delivery"
    FEEDBACK = "feedback"

    def self.delivery?(digest)
      where(key_type: DELIVERY, digest: digest).exists?
    end

    def self.feedback(digest)
      return if digest.blank?
      find_by(key_type: FEEDBACK, digest: digest)
    end
  end
end

# == Schema Information
#
# Table name: discourse_plunk_tombstones
#
#  id                   :bigint           not null, primary key
#  digest               :string(64)       not null
#  key_type             :string(16)       not null
#  kind                 :string(32)       not null
#  original_received_at :datetime
#  preference_applied   :boolean          default(FALSE), not null
#  score_applied        :boolean          default(FALSE), not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  original_event_id    :bigint
#
# Indexes
#
#  idx_discourse_plunk_tombstones_key  (key_type,digest) UNIQUE
#
