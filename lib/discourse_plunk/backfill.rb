# frozen_string_literal: true

module DiscoursePlunk
  # Deliberate, administrator-run replay of known historical feedback through
  # the same validation, ledger and Processor as live webhooks.
  #
  # Input is a JSON file holding one Plunk default-body payload or an array of
  # them, all for the same route. Nothing is fetched from Plunk; the operator
  # supplies the records (for example exported from Plunk's dashboard). Each
  # record needs its own workflow.id / execution.id pair — a replay of a pair
  # already on file is recognised as a duplicate, exactly as a live replay is.
  module Backfill
    Outcome = Data.define(:index, :status, :receipt_id, :detail)

    def self.run(route, path)
      kind = DiscoursePlunk::ROUTES.fetch(route) { raise ArgumentError, "unknown route #{route}" }
      if !SiteSetting.plunk_feedback_enabled
        raise Discourse::InvalidAccess, "plunk_feedback_enabled is off"
      end

      document = JSON.parse(File.read(path), max_nesting: 16)
      records = document.is_a?(Array) ? document : [document]

      records.each_with_index.map { |record, index| replay(kind, record, index) }
    end

    def self.replay(kind, record, index)
      parsed = Payload.parse(kind, record)
      result = Receiver.accept(parsed, source: "backfill")

      case result.status
      when :created
        event = Processor.process(result.event, trigger: :admin)
        Outcome.new(index:, status: event.status, receipt_id: event.id, detail: event.outcome)
      when :duplicate
        Outcome.new(index:, status: "duplicate", receipt_id: result.event.id, detail: nil)
      when :tombstoned
        Outcome.new(index:, status: "duplicate", receipt_id: nil, detail: "history purged")
      else
        Outcome.new(
          index:,
          status: "conflict",
          receipt_id: result.event.id,
          detail: "workflow/execution id already used for different feedback",
        )
      end
    rescue Payload::Invalid => e
      Outcome.new(index:, status: "invalid", receipt_id: nil, detail: e.errors.join("; "))
    end
  end
end
