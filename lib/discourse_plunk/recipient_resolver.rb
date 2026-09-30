# frozen_string_literal: true

module DiscoursePlunk
  # Finds the one Discourse account that currently owns a recipient address.
  #
  # Uses user_emails, the table core's User.find_by_email reads, with the same
  # lower(email) comparison. Primary and secondary rows both count: a
  # secondary address only exists in user_emails after the owner confirmed it
  # (unconfirmed additions live in email_change_requests), so every row here
  # is an address core itself would mail. Nothing is fuzzy — no plus-tag or
  # dot stripping, no normalized_email, no name matching.
  class RecipientResolver
    # status: :matched, :unknown, :ambiguous or :non_human
    Result = Data.define(:status, :user, :match_method)

    def self.resolve(recipient)
      rows = UserEmail.where("lower(email) = ?", recipient).limit(2).pluck(:user_id, :primary)

      # lower(email) is unique, so this cannot happen on a healthy database;
      # if it ever does, refusing to pick is the only safe answer.
      return result(:ambiguous) if rows.map(&:first).uniq.size > 1
      return result(:unknown) if rows.empty?

      user_id, primary = rows.first
      user = User.find_by(id: user_id)
      return result(:unknown) if user.nil?
      return result(:non_human) if !user.human?

      method =
        if !primary
          "secondary_email"
        elsif user.active?
          "primary_email"
        else
          "primary_email_unactivated"
        end

      Result.new(status: :matched, user: user, match_method: method)
    end

    # True when the address still belongs to this user right now. Called inside
    # each effect's transaction, so delayed or retried work never lands on an
    # account that has since given the address up.
    def self.owned_by?(user, recipient)
      UserEmail.where(user_id: user.id).where("lower(email) = ?", recipient).exists?
    end

    def self.result(status)
      Result.new(status: status, user: nil, match_method: nil)
    end
  end
end
