# frozen_string_literal: true

module DiscoursePlunk
  # Validates Plunk's default workflow-webhook body and normalises it into one
  # internal event.
  #
  # Plunk's default body is
  #
  #   { contact:   { email, subscribed, data },
  #     workflow:  { id, name },
  #     execution: { id, startedAt },
  #     event:     <the trigger event's data> }
  #
  # It has no event-name field, so the event kind always comes from the route
  # the request arrived on, never from the body. Only the fields listed here
  # are kept; contact data, subjects, sender addresses and anything else in
  # the body are validated where needed and then dropped.
  class Payload
    class Invalid < StandardError
      attr_reader :errors

      def initialize(errors)
        @errors = errors
        super(errors.join("; "))
      end
    end

    EMAIL_MAX = 254
    IDENTIFIER_MAX = 191
    MESSAGE_ID_MAX = 512
    NAME_MAX = 191
    REASON_MAX = 64
    BOUNCE_TYPE_MAX = 64
    SOURCE_TYPE_MAX = 32
    TIMESTAMP_MAX = 64
    CONTROL_CHARACTERS = /[[:cntrl:]]/
    # String#strip also removes NUL; trim ordinary whitespace only, so any
    # other control character is still seen (and rejected).
    SURROUNDING_WHITESPACE = /\A[ \t\r\n]+|[ \t\r\n]+\z/

    Event =
      Data.define(
        :kind,
        :recipient,
        :contact_subscribed,
        :workflow_id,
        :workflow_name,
        :execution_id,
        :execution_started_at,
        :plunk_email_id,
        :provider_message_id,
        :bounce_classification,
        :bounce_type,
        :unsubscribe_reason,
        :source_type,
        :occurred_at,
        :received_at,
      ) do
        # Identity of the HTTP delivery: one Plunk workflow execution posting
        # to one route. Replays of the same execution share it.
        def delivery_digest
          Payload.digest("delivery", kind, workflow_id, execution_id)
        end

        # What the delivery says happened. A replay must say the same thing;
        # a reused delivery identity that says something else is a conflict.
        def identity_digest
          Payload.digest(
            "identity",
            kind,
            recipient,
            plunk_email_id,
            provider_message_id,
            bounce_classification,
            unsubscribe_reason,
          )
        end

        # Identity of the underlying bounce or complaint, independent of which
        # workflow execution delivered it: recipient, actual kind, Plunk's
        # stable email id (or the provider message id when that is all there
        # is) and, for bounces, the classification — so a soft bounce followed
        # by a hard bounce for the same message is two pieces of feedback, not
        # one. Nil when there is no stable identifier; such events are never
        # merged with each other. Unsubscribes have none by design: each
        # contact.unsubscribed is a distinct opt-out.
        def feedback_digest
          return if kind == FeedbackEvent::UNSUBSCRIBE
          stable_id =
            if plunk_email_id.present?
              "email:#{plunk_email_id}"
            elsif provider_message_id.present?
              "message:#{provider_message_id}"
            end
          return if stable_id.nil?

          Payload.digest("feedback", kind, recipient, stable_id, bounce_classification)
        end
      end

    def self.digest(*parts)
      Digest::SHA256.hexdigest(parts.map(&:to_s).join("\u0000"))
    end

    def self.parse(kind, document, received_at: Time.zone.now)
      new(kind, document, received_at).parse
    end

    def initialize(kind, document, received_at)
      @kind = kind
      @document = document
      @received_at = received_at
      @errors = []
    end

    def parse
      raise ArgumentError, "unknown kind #{@kind}" if FeedbackEvent::KINDS.exclude?(@kind)
      raise Invalid.new(["body must be a JSON object"]) unless @document.is_a?(Hash)

      contact = object(@document, "contact", required: true)
      workflow = object(@document, "workflow", required: true)
      execution = object(@document, "execution", required: true)
      event = object(@document, "event", required: @kind != FeedbackEvent::UNSUBSCRIBE)

      recipient = contact && recipient_from(contact)
      contact_subscribed = contact && boolean(contact, "contact.subscribed")
      object(contact, "contact.data", required: false) if contact

      workflow_id = workflow && identifier(workflow, "workflow.id", max: IDENTIFIER_MAX)
      workflow_name = workflow && label(workflow, "workflow.name", max: NAME_MAX)
      execution_id = execution && identifier(execution, "execution.id", max: IDENTIFIER_MAX)
      execution_started_at = execution && timestamp(execution, "execution.startedAt")

      details = event_details(event || {})

      raise Invalid.new(@errors) if @errors.any?

      Event.new(
        kind: @kind,
        recipient: recipient,
        contact_subscribed: contact_subscribed,
        workflow_id: workflow_id,
        workflow_name: workflow_name,
        execution_id: execution_id,
        execution_started_at: execution_started_at,
        received_at: @received_at,
        **details,
      )
    end

    private

    def event_details(event)
      details = {
        plunk_email_id: nil,
        provider_message_id: nil,
        bounce_classification: nil,
        bounce_type: nil,
        unsubscribe_reason: nil,
        source_type: nil,
        occurred_at: nil,
      }

      case @kind
      when FeedbackEvent::UNSUBSCRIBE
        # Empty by default; Plunk adds `reason` ("bounce", "complaint",
        # "snooze") for automatic changes. The reason is recorded, never
        # treated as a second bounce or complaint.
        details[:unsubscribe_reason] = optional_string(event, "event.reason", max: REASON_MAX)
      when FeedbackEvent::COMPLAINT
        details.merge!(email_fields(event))
        details[:occurred_at] = timestamp(event, "event.complainedAt")
      when FeedbackEvent::BOUNCE
        details.merge!(email_fields(event))
        details[:occurred_at] = timestamp(event, "event.bouncedAt")
        bounce_type = optional_string(event, "event.bounceType", max: BOUNCE_TYPE_MAX)
        transient_flag = boolean(event, "event.transientBounce")
        details[:bounce_type] = bounce_type
        details[:bounce_classification] = classify_bounce(bounce_type, transient_flag)
      end

      details
    end

    def email_fields(event)
      {
        plunk_email_id: optional_identifier(event, "event.emailId", max: IDENTIFIER_MAX),
        provider_message_id: optional_identifier(event, "event.messageId", max: MESSAGE_ID_MAX),
        source_type: optional_string(event, "event.sourceType", max: SOURCE_TYPE_MAX),
      }
    end

    # Plunk passes SES's bounceType through: "Permanent", "Transient" or
    # "Undetermined". Only an explicit value is trusted; anything missing,
    # unrecognised or self-contradictory is "unknown" — never promoted to
    # permanent.
    def classify_bounce(bounce_type, transient_flag)
      case bounce_type&.downcase
      when "permanent"
        transient_flag == true ? "unknown" : "permanent"
      when "transient"
        "transient"
      when nil
        transient_flag == true ? "transient" : "unknown"
      else
        "unknown"
      end
    end

    def recipient_from(contact)
      value = contact["email"]
      if !value.is_a?(String)
        @errors << (value.nil? ? "contact.email is required" : "contact.email must be a string")
        return
      end

      email = trim(value)
      if email.empty?
        @errors << "contact.email is required"
      elsif email.length > EMAIL_MAX || email.match?(CONTROL_CHARACTERS) || !Email.is_valid?(email)
        @errors << "contact.email is not a valid email address"
      else
        # Discourse stores and compares addresses lower-cased (UserEmail
        # before_validation). Nothing else is normalised: plus tags and dots
        # are part of the address.
        return Email.downcase(email)
      end

      nil
    end

    def object(hash, path, required:)
      key = path.split(".").last
      value = hash[key]
      if value.nil?
        @errors << "#{path} is required" if required
        nil
      elsif !value.is_a?(Hash)
        @errors << "#{path} must be an object"
        nil
      else
        value
      end
    end

    def boolean(hash, path)
      key = path.split(".").last
      value = hash[key]
      return if value.nil?
      return value if value == true || value == false

      # Deliberately strict: the string "false" is not false.
      @errors << "#{path} must be a boolean"
      nil
    end

    def identifier(hash, path, max:)
      errors_before = @errors.size
      value = optional_identifier(hash, path, max: max)
      @errors << "#{path} is required" if value.nil? && @errors.size == errors_before
      value
    end

    def optional_identifier(hash, path, max:)
      value = optional_string(hash, path, max: max)
      return if value.nil?

      if value.match?(/\s/)
        @errors << "#{path} must not contain whitespace"
        return
      end

      value
    end

    def optional_string(hash, path, max:)
      key = path.split(".").last
      value = hash[key]
      return if value.nil?

      if !value.is_a?(String)
        @errors << "#{path} must be a string"
        return
      end

      value = trim(value)
      return if value.empty?

      if value.length > max
        @errors << "#{path} must be at most #{max} characters"
        return
      end

      if value.match?(CONTROL_CHARACTERS)
        @errors << "#{path} must not contain control characters"
        return
      end

      value
    end

    # Display-only text: bounded by truncation rather than rejection.
    def label(hash, path, max:)
      key = path.split(".").last
      value = hash[key]
      return if value.nil?

      if !value.is_a?(String)
        @errors << "#{path} must be a string"
        return
      end

      trim(value.gsub(CONTROL_CHARACTERS, " ")).truncate(max).presence
    end

    def trim(value)
      value.gsub(SURROUNDING_WHITESPACE, "")
    end

    def timestamp(hash, path)
      value = optional_string(hash, path, max: TIMESTAMP_MAX)
      return if value.nil?

      Time.iso8601(value)
    rescue ArgumentError
      @errors << "#{path} must be an ISO 8601 timestamp"
      nil
    end
  end
end
