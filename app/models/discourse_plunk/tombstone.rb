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
