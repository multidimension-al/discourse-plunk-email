# frozen_string_literal: true

module DiscoursePlunk
  # Receives Plunk workflow webhooks.
  #
  # Like core's WebhooksController this is an ActionController::Base, not an
  # ApplicationController: there is no browser session, so login_required,
  # the XHR/CSRF checks and the "redirect to login" behaviour never apply.
  # Forgery protection is skipped for these three machine-to-machine actions
  # only; the bearer secret is the one and only credential.
  #
  # Status codes (the JSON body always says which case it is):
  #   200 processed   every phase finished (including "no such account")
  #   200 duplicate   a replay of a delivery already processed
  #   202 accepted    durable receipt; unfinished work is retried by jobs
  #   400/413/415/422 malformed request; nothing stored, nothing changed
  #   401             missing or wrong secret
  #   405             not a POST
  #   409             delivery identity reused with different content
  #   500/503         could not process or safely accept; Plunk must show it
  #
  # No requires_plugin: while the plugin is disabled every request is refused
  # below with an explicit 503 "receiver_disabled", which Plunk's execution
  # log shows verbatim, rather than an anonymous 404.
  class WebhooksController < ::ActionController::Base # rubocop:disable Discourse/Plugins/CallRequiresPlugin
    include ::ReadOnlyMixin

    MAX_BODY_BYTES = 64.kilobytes
    JSON_MAX_NESTING = 16

    skip_forgery_protection
    # Otherwise Rails copies the JSON body under a "webhook" key, and that
    # copy would escape the contact/event/... log filters in plugin.rb.
    wrap_parameters false
    before_action :check_readonly_mode
    before_action :block_if_readonly_mode, except: :method_not_allowed

    rescue_from Discourse::ReadOnly do
      respond(503, status: "rejected", error: "read_only")
    end

    def unsubscribe
      receive("unsubscribe")
    end

    def complaint
      receive("complaint")
    end

    def bounce
      receive("bounce")
    end

    def method_not_allowed
      response.headers["Allow"] = "POST"
      respond(405, status: "rejected", error: "method_not_allowed")
    end

    private

    def receive(route)
      if !SiteSetting.plunk_feedback_enabled
        return respond(503, status: "rejected", error: "receiver_disabled")
      end
      if SiteSetting.plunk_feedback_webhook_secret.blank?
        return respond(503, status: "rejected", error: "receiver_not_configured")
      end
      return respond(401, status: "rejected", error: "unauthorized") if !authenticated?

      # The secret belongs in the Authorization header only. Anything in the
      # query string means the URL was set up wrong (and may have leaked a
      # secret into a proxy log); fail loudly instead of accepting it.
      if request.query_string.present?
        return respond(400, status: "rejected", error: "unexpected_query_string")
      end
      if request.media_type != "application/json"
        return respond(415, status: "rejected", error: "unsupported_media_type")
      end

      body = read_body
      return respond(413, status: "rejected", error: "payload_too_large") if body.nil?
      if !body.force_encoding(Encoding::UTF_8).valid_encoding?
        return respond(400, status: "rejected", error: "invalid_encoding")
      end

      document =
        begin
          JSON.parse(body, max_nesting: JSON_MAX_NESTING)
        rescue JSON::ParserError, JSON::NestingError
          return respond(400, status: "rejected", error: "invalid_json")
        end

      parsed =
        begin
          Payload.parse(DiscoursePlunk::ROUTES.fetch(route), document)
        rescue Payload::Invalid => e
          return respond(422, status: "rejected", error: "invalid_payload", details: e.errors)
        end

      result = Receiver.accept(parsed)
      case result.status
      when :tombstoned
        respond(200, status: "duplicate")
      when :conflict
        respond(409, status: "conflict", error: "delivery_identity_conflict")
      when :duplicate
        respond_for(result.event, duplicate: true)
      else
        respond_for(Processor.process(result.event, trigger: :webhook))
      end
    rescue StandardError => e
      Rails.logger.error("discourse-plunk: webhook #{route} failed: #{e.class}")
      respond(500, status: "failed", error: "internal_error")
    end

    def authenticated?
      scheme, token = request.authorization.to_s.split(" ", 2)
      return false if !scheme&.casecmp?("Bearer") || token.blank?
      token = token.strip

      secrets = [
        SiteSetting.plunk_feedback_webhook_secret,
        SiteSetting.plunk_feedback_webhook_previous_secret,
      ].select(&:present?)

      # Compare against every configured secret (never short-circuit) in
      # constant time; an empty secret can never match.
      secrets.map { |secret| ActiveSupport::SecurityUtils.secure_compare(secret, token) }.any?
    end

    # Refuses on the declared length first; raw_post (which Rails caches and
    # which does not depend on a rewindable rack.input) is then re-checked,
    # since a chunked request declares no length. nginx's
    # client_max_body_size bounds what can be read at all.
    def read_body
      return if request.content_length.to_i > MAX_BODY_BYTES

      body = request.raw_post.to_s
      body.bytesize > MAX_BODY_BYTES ? nil : body.dup
    end

    def respond_for(event, duplicate: false)
      body = { receipt_id: event.id }
      body[:duplicate] = true if duplicate

      if FeedbackEvent::TERMINAL_STATUSES.include?(event.status)
        respond(200, status: duplicate ? "duplicate" : "processed", **body)
      elsif event.status == "failed" && event.next_attempt_at.nil?
        respond(500, status: "failed", error: "processing_failed", **body)
      elsif Recovery.healthy?
        # Durably received, some phase unfinished, and the job system that
        # retries it is running.
        respond(202, status: "accepted", **body)
      else
        respond(503, status: "failed", error: "processing_incomplete", **body)
      end
    end

    def respond(code, body)
      response.headers["Cache-Control"] = "no-store"
      render json: body, status: code
    end
  end
end
