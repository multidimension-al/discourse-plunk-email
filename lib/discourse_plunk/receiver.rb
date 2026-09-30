# frozen_string_literal: true

module DiscoursePlunk
  # Turns a validated delivery into a durable receipt, exactly once.
  #
  # The database decides what is new: the (kind, workflow_id, execution_id)
  # unique index makes concurrent copies of one delivery collapse into a
  # single row. A receipt is only proof that the delivery arrived; the
  # Processor records separately what was actually done about it.
  class Receiver
    # created     a new receipt; the caller should process it
    # duplicate   a replay of a delivery already on file (same content)
    # conflict    a delivery identity reused with different content
    # tombstoned  a replay of a delivery whose history was purged
    Result = Data.define(:status, :event)

    def self.accept(parsed, source: "webhook")
      new(parsed, source).accept
    end

    def initialize(parsed, source)
      @parsed = parsed
      @source = source
    end

    def accept
      if Tombstone.delivery?(@parsed.delivery_digest)
        return Result.new(status: :tombstoned, event: nil)
      end

      rows =
        FeedbackEvent.insert_all(
          [attributes],
          unique_by: :idx_discourse_plunk_events_delivery,
          returning: %w[id],
        )
      if (id = rows.first&.fetch("id"))
        return Result.new(status: :created, event: FeedbackEvent.find(id))
      end

      existing =
        FeedbackEvent.find_by!(
          kind: @parsed.kind,
          workflow_id: @parsed.workflow_id,
          execution_id: @parsed.execution_id,
        )
      now = Time.zone.now

      if existing.identity_digest == @parsed.identity_digest
        FeedbackEvent.where(id: existing.id).update_all(
          ["delivery_count = delivery_count + 1, last_delivery_at = ?", now],
        )
        Result.new(status: :duplicate, event: existing.reload)
      else
        FeedbackEvent.where(id: existing.id).update_all(
          [
            "identity_conflict_count = identity_conflict_count + 1, last_identity_conflict_at = ?",
            now,
          ],
        )
        Rails.logger.warn(
          "discourse-plunk: delivery identity reused with different content (receipt #{existing.id})",
        )
        Result.new(status: :conflict, event: existing.reload)
      end
    end

    private

    def attributes
      p = @parsed
      {
        kind: p.kind,
        source: @source,
        workflow_id: p.workflow_id,
        workflow_name: p.workflow_name,
        execution_id: p.execution_id,
        execution_started_at: p.execution_started_at,
        recipient: p.recipient,
        contact_subscribed: p.contact_subscribed,
        plunk_email_id: p.plunk_email_id,
        provider_message_id: p.provider_message_id,
        bounce_classification: p.bounce_classification,
        bounce_type: p.bounce_type,
        unsubscribe_reason: p.unsubscribe_reason,
        source_type: p.source_type,
        occurred_at: p.occurred_at,
        received_at: p.received_at,
        last_delivery_at: p.received_at,
        delivery_digest: p.delivery_digest,
        identity_digest: p.identity_digest,
        feedback_digest: p.feedback_digest,
        # Unsubscribes never touch the bounce score, and only a bounce can
        # mark an EmailLog as bounced; those phases are settled on arrival.
        score_state: p.kind == FeedbackEvent::UNSUBSCRIBE ? "not_applicable" : "pending",
        correlation_state: p.kind == FeedbackEvent::BOUNCE ? "pending" : "not_applicable",
      }
    end
  end
end
