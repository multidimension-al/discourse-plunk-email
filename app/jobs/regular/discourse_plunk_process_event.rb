# frozen_string_literal: true

module Jobs
  # Retries one receipt's unfinished phases (scheduled by the Processor with
  # backoff after a failure).
  class DiscoursePlunkProcessEvent < ::Jobs::Base
    def execute(args)
      return if !SiteSetting.plunk_feedback_enabled
      return if args[:event_id].blank?
      return if !DiscoursePlunk::FeedbackEvent.exists?(id: args[:event_id])

      DiscoursePlunk::Processor.process(args[:event_id], trigger: :retry)
    end
  end
end
