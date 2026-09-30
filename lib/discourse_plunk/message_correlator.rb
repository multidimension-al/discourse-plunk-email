# frozen_string_literal: true

module DiscoursePlunk
  # Links feedback to the Discourse EmailLog it is about — when, and only
  # when, the evidence is exact.
  #
  # Discourse stores the RFC Message-ID it generated (EmailLog#message_id) and
  # the SMTP server's reply (smtp_transaction_response). Plunk reports its own
  # email id and a provider message id, which need not equal either. The only
  # match accepted is: EmailLog.message_id equals the reported messageId
  # (ignoring RFC angle brackets) AND the log was addressed to this recipient.
  # No substring scraping of SMTP responses, no VERP guessing, no "latest
  # email to this address". Correlation is evidence; it is never required
  # before the account-level preference change.
  class MessageCorrelator
    Result =
      Data.define(:label, :email_log_id) do
        def conflict?
          label == "message_user_conflict"
        end

        def matched?
          label == "message_matched"
        end

        def lookup_failed?
          label == "lookup_failed"
        end
      end

    def self.correlate(event, user)
      new(event, user).correlate
    end

    def initialize(event, user)
      @event = event
      @user = user
    end

    def correlate
      message_id = @event.provider_message_id
      return result("no_message_identifier") if message_id.blank?

      candidates = [message_id, message_id.delete_prefix("<").delete_suffix(">")].uniq
      logs =
        EmailLog
          .where(message_id: candidates)
          .where("lower(to_address) = ?", @event.recipient)
          .order(:id)
          .limit(2)
          .pluck(:id, :user_id)

      case logs.size
      when 0
        result("user_matched_message_unmatched")
      when 1
        log_id, log_user_id = logs.first
        if log_user_id.present? && log_user_id != @user.id
          # The message was sent to another account at this address. Record
          # it; the Processor applies nothing across accounts.
          result("message_user_conflict", log_id)
        else
          result("message_matched", log_id)
        end
      else
        result("message_ambiguous")
      end
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn("discourse-plunk: EmailLog lookup failed for receipt #{@event.id}: #{e.class}")
      result("lookup_failed")
    end

    private

    def result(label, email_log_id = nil)
      Result.new(label: label, email_log_id: email_log_id)
    end
  end
end
