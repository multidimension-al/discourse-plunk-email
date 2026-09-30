# frozen_string_literal: true

module Jobs
  # Safety net for receipts whose processing never finished: a crash between
  # committing the receipt and processing it, or a retry job that was lost.
  class DiscoursePlunkRecoverEvents < ::Jobs::Scheduled
    every 5.minutes

    def execute(_args)
      DiscoursePlunk::Recovery.sweep
    end
  end
end
