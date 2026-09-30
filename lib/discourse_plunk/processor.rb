# frozen_string_literal: true

module DiscoursePlunk
  # The single, idempotent service every path goes through: the webhook
  # request, the retry job, the recovery sweep, the admin "reprocess" button
  # and the backfill rake task.
  #
  # Phases, each committed in its own transaction together with its marker:
  #
  #   1. preferences  every optional-email preference off (all three kinds)
  #   2. score        native bounce score via Email::Receiver.update_bounce_score
  #                   (complaints and bounces only)
  #   3. correlation  EmailLog.bounced for an exactly matched message (bounces
  #                   only)
  #
  # The preference change commits first, so a later failure in scoring or
  # bookkeeping can never undo it. A phase whose marker says it is done is
  # never run again, so a retry, a replay or an admin reprocess cannot
  # re-apply an effect — including after the user has since opted back in.
  class Processor
    class OwnershipChanged < StandardError
    end

    class CorrelationPending < StandardError
    end

    MUTEX_VALIDITY = 60

    def self.process(event, trigger:)
      new(event, trigger).process
    end

    def initialize(event, trigger)
      @event_id = event.is_a?(FeedbackEvent) ? event.id : event
      @trigger = trigger
    end

    def process
      DistributedMutex.synchronize("discourse_plunk_event_#{@event_id}", validity: MUTEX_VALIDITY) do
        @event = FeedbackEvent.find(@event_id)
        run if runnable?
      end
      FeedbackEvent.find(@event_id)
    end

    private

    def runnable?
      return false if @event.status == "processed"
      # Unmatched and conflicting events never retry on their own; only an
      # administrator can ask for them to be looked at again.
      return @trigger == :admin if @event.terminal?
      return true if @trigger == :admin || @trigger == :webhook
      @event.next_attempt_at.nil? || @event.next_attempt_at <= Time.zone.now
    end

    def run
      @phase = "resolve"
      now = Time.zone.now
      @event.update_columns(
        status: "processing",
        attempts: @event.attempts + 1,
        last_attempt_at: now,
        next_attempt_at: nil,
        updated_at: now,
      )

      resolution = RecipientResolver.resolve(@event.recipient)

      if resolution.status != :matched
        # An address that matched on an earlier attempt and no longer does has
        # changed hands (or been removed) while work was pending.
        return finish_conflict("recipient_owner_changed") if @event.user_id.present?
        case resolution.status
        when :unknown
          return finish_without_account("unmatched", "unknown_recipient")
        when :non_human
          return finish_without_account("unmatched", "non_human_account")
        else
          return finish_without_account("conflict", "ambiguous_recipient")
        end
      end

      user = resolution.user
      if @event.user_id.present? && @event.user_id != user.id
        return finish_conflict("recipient_owner_changed")
      end
      @event.update_columns(user_id: user.id, match_method: resolution.match_method)

      @phase = "correlation_lookup"
      correlation = MessageCorrelator.correlate(@event, user)
      @event.update_columns(correlation: correlation.label, email_log_id: correlation.email_log_id)
      return finish_conflict("message_user_conflict") if correlation.conflict?

      @phase = "preference"
      apply_preferences(user)
      @phase = "score"
      apply_score(user)
      @phase = "correlation"
      apply_correlation(correlation)

      finish_processed
    rescue OwnershipChanged
      finish_conflict("recipient_owner_changed")
    rescue StandardError => e
      record_failure(e)
    end

    def apply_preferences(user)
      return if finished?(@event.preference_state)

      FeedbackEvent.transaction do
        event = FeedbackEvent.lock.find(@event.id)
        next if finished?(event.preference_state)

        option = user.user_option
        raise ActiveRecord::RecordNotFound, "user_option missing" if option.nil?
        option.lock!
        ensure_owned!(user, event)

        if (prior = prior_feedback(event, :preference_applied))
          event.update!(
            preference_state: "skipped",
            duplicate_of_event_id: event.duplicate_of_event_id || prior,
          )
          next
        end

        preferences = OptionalEmailPreferences.new(user)
        changes = preferences.disable_all!
        event.update!(
          preference_state: "done",
          preference_changes: {
            "changes" => changes,
            "strategies" => preferences.strategies_used,
          },
          preference_applied_at: Time.zone.now,
        )
        log_staff_action(user, event, changes) if changes.present?
      end

      @event.reload
    end

    def apply_score(user)
      return if finished?(@event.score_state)

      score, effect = native_score
      FeedbackEvent.transaction do
        event = FeedbackEvent.lock.find(@event.id)
        next if finished?(event.score_state)

        # Serialises every read-modify-write of this user's bounce score done
        # by this plugin; update_bounce_score re-reads the row after the lock.
        stat = UserStat.lock.find_by(user_id: user.id)
        raise ActiveRecord::RecordNotFound, "user_stat missing" if stat.nil?
        ensure_owned!(user, event)

        if (prior = prior_feedback(event, :score_applied))
          event.update!(
            score_state: "skipped",
            score_effect: "duplicate_feedback",
            duplicate_of_event_id: event.duplicate_of_event_id || prior,
          )
          next
        end

        if score <= 0
          event.update!(score_state: "skipped", score_effect: "#{effect}_is_zero", score_delta: 0)
          next
        end

        before = stat.bounce_score
        # Core's own updater: threshold, reset_bounce_score_after, the staff
        # "revoke email" log and the user's system message all stay native.
        # It runs in this transaction, with the marker below, so the score
        # and its idempotency record commit — or roll back — together.
        Email::Receiver.update_bounce_score(event.recipient, score)
        after = UserStat.where(user_id: user.id).pick(:bounce_score)

        event.update!(
          score_state: "done",
          score_effect: effect,
          score_delta: score,
          bounce_score_before: before,
          bounce_score_after: after,
          score_applied_at: Time.zone.now,
        )
      end

      @event.reload
    end

    def apply_correlation(correlation)
      return if finished?(@event.correlation_state)
      # Retry later; the account-level effects above are already committed.
      raise CorrelationPending, "EmailLog lookup failed" if correlation.lookup_failed?

      if !correlation.matched?
        @event.update_columns(correlation_state: "not_applicable")
        return
      end

      FeedbackEvent.transaction do
        event = FeedbackEvent.lock.find(@event.id)
        next if finished?(event.correlation_state)

        # Plunk supplies no SMTP status, so bounce_error_code is left alone
        # rather than invented.
        EmailLog.where(id: correlation.email_log_id).update_all(bounced: true)
        event.update!(correlation_state: "done", correlation_applied_at: Time.zone.now)
      end

      @event.reload
    end

    # Complaints use the hard-bounce score, as core's own Postmark adapter
    # does; the event keeps its complaint classification. An unknown bounce
    # classification is scored as soft: a delivery failure happened, but
    # there is no evidence it was permanent.
    def native_score
      if @event.complaint? || @event.bounce_classification == "permanent"
        [SiteSetting.hard_bounce_score, "hard_bounce_score"]
      else
        [SiteSetting.soft_bounce_score, "soft_bounce_score"]
      end
    end

    # Another receipt of the same bounce/complaint (same feedback digest)
    # that already applied this effect — live, or purged into a tombstone.
    def prior_feedback(event, flag)
      return if event.feedback_digest.blank?

      column = flag == :preference_applied ? :preference_state : :score_state
      prior =
        FeedbackEvent
          .where(feedback_digest: event.feedback_digest, column => "done")
          .where.not(id: event.id)
          .order(:id)
          .pick(:id)
      return prior if prior

      tombstone = Tombstone.feedback(event.feedback_digest)
      tombstone.original_event_id || 0 if tombstone&.public_send(flag)
    end

    def ensure_owned!(user, event)
      raise OwnershipChanged if !RecipientResolver.owned_by?(user, event.recipient)
    end

    def log_staff_action(user, event, changes)
      summary = changes.map { |column, (from, to)| "#{column}: #{from} → #{to}" }.join("; ")
      UserHistory.create!(
        action: UserHistory.actions[:custom_staff],
        custom_type: "plunk_feedback_email_opt_out",
        acting_user_id: Discourse.system_user.id,
        target_user_id: user.id,
        context: "#{event.kind} (Plunk feedback receipt ##{event.id})",
        details: summary.truncate(UserHistory::MAX_CONTEXT_LENGTH),
      )
    end

    def finished?(state)
      FeedbackEvent::PHASE_FINISHED.include?(state)
    end

    def finish_processed
      outcome =
        if @event.preference_state == "done"
          @event.preference_changes.dig("changes").present? ? "applied" : "already_unsubscribed"
        elsif @event.duplicate_of_event_id.present?
          "duplicate_feedback"
        else
          "no_change"
        end

      finish("processed", outcome)
    end

    def finish_without_account(status, outcome)
      skip_pending_phases
      finish(status, outcome)
    end

    def finish_conflict(outcome)
      skip_pending_phases
      finish("conflict", outcome)
    end

    def skip_pending_phases
      attrs = {}
      %i[preference_state score_state correlation_state].each do |phase|
        attrs[phase] = "skipped" if !finished?(@event.public_send(phase))
      end
      @event.update_columns(attrs) if attrs.any?
    end

    def finish(status, outcome)
      now = Time.zone.now
      @event.update_columns(
        status: status,
        outcome: outcome,
        processed_at: now,
        next_attempt_at: nil,
        last_error: nil,
        updated_at: now,
      )
    end

    def record_failure(error)
      @event.reload
      attempts = @event.attempts
      retry_at =
        (Time.zone.now + FeedbackEvent.backoff_for(attempts) if attempts < FeedbackEvent::MAX_ATTEMPTS)

      attrs = {
        status: "failed",
        outcome: retry_at ? "retry_scheduled" : "retries_exhausted",
        last_error: self.class.sanitize_error(error, @phase),
        next_attempt_at: retry_at,
        updated_at: Time.zone.now,
      }
      phase_column = { "preference" => :preference_state, "score" => :score_state }[@phase]
      phase_column ||= :correlation_state if @phase == "correlation"
      attrs[phase_column] = "failed" if phase_column && !finished?(@event.public_send(phase_column))
      @event.update_columns(attrs)

      Rails.logger.warn(
        "discourse-plunk: receipt #{@event.id} failed in #{@phase} (attempt #{attempts}): #{error.class}",
      )

      if retry_at
        Jobs.enqueue_at(retry_at, :discourse_plunk_process_event, event_id: @event.id)
      end
    end

    EMAIL_PATTERN = /[^\s@<>"'(),;:]+@[^\s@<>"'(),;:]+/

    # Exception messages can carry SQL fragments with addresses in them; keep
    # the class and a redacted, bounded message.
    def self.sanitize_error(error, phase)
      message = error.message.to_s.gsub(EMAIL_PATTERN, "[email]").squish
      "#{phase}: #{error.class}: #{message}".truncate(1000)
    end
  end
end
