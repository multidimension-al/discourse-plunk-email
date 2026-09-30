# frozen_string_literal: true

require_relative "../support/plunk_helpers"

RSpec.describe DiscoursePlunk::WebhooksController do
  fab!(:user) { Fabricate(:user, email: "plunk-test@example.com") }

  let(:complaint) { plunk_payload("synthetic-email-complaint", email: user.email) }

  before { enable_plunk! }

  describe "authentication and configuration" do
    it "rejects requests while the plugin is disabled" do
      SiteSetting.plunk_feedback_enabled = false
      post_plunk("complaint", complaint)

      expect(response.status).to eq(503)
      expect(response.parsed_body["error"]).to eq("receiver_disabled")
      expect(DiscoursePlunk::FeedbackEvent.count).to eq(0)
      expect(email_off?(user)).to eq(false)
    end

    it "rejects requests while no secret is configured, even with an empty bearer token" do
      SiteSetting.plunk_feedback_webhook_secret = ""
      post_plunk("complaint", complaint, headers: plunk_headers(secret: ""))

      expect(response.status).to eq(503)
      expect(response.parsed_body["error"]).to eq("receiver_not_configured")
      expect(DiscoursePlunk::FeedbackEvent.count).to eq(0)
    end

    it "rejects a missing Authorization header" do
      post_plunk("complaint", complaint, headers: { "CONTENT_TYPE" => "application/json" })

      expect(response.status).to eq(401)
      expect(DiscoursePlunk::FeedbackEvent.count).to eq(0)
      expect(email_off?(user)).to eq(false)
    end

    it "rejects a wrong secret" do
      post_plunk("complaint", complaint, headers: plunk_headers(secret: SecureRandom.base64(48)))

      expect(response.status).to eq(401)
      expect(DiscoursePlunk::FeedbackEvent.count).to eq(0)
    end

    it "rejects a non-Bearer scheme carrying the right secret" do
      post_plunk(
        "complaint",
        complaint,
        headers: {
          "Authorization" => "Basic #{plunk_secret}",
          "CONTENT_TYPE" => "application/json",
        },
      )

      expect(response.status).to eq(401)
    end

    it "does not accept the secret from the query string" do
      post "/discourse-plunk/webhooks/complaint?token=#{CGI.escape(plunk_secret)}",
           params: complaint.to_json,
           headers: {
             "CONTENT_TYPE" => "application/json",
           }

      expect(response.status).to eq(401)
      expect(DiscoursePlunk::FeedbackEvent.count).to eq(0)
    end

    it "rejects an otherwise valid request that also carries a query string" do
      post "/discourse-plunk/webhooks/complaint?x=1",
           params: complaint.to_json,
           headers: plunk_headers

      expect(response.status).to eq(400)
      expect(response.parsed_body["error"]).to eq("unexpected_query_string")
    end

    it "accepts the previous secret during a rotation, and stops once it is cleared" do
      old_secret = plunk_secret
      new_secret = SecureRandom.base64(48)
      SiteSetting.plunk_feedback_webhook_previous_secret = old_secret
      SiteSetting.plunk_feedback_webhook_secret = new_secret

      post_plunk("complaint", complaint, headers: plunk_headers(secret: old_secret))
      expect(response.status).to eq(200)

      SiteSetting.plunk_feedback_webhook_previous_secret = ""
      post_plunk(
        "complaint",
        plunk_payload("synthetic-email-complaint", email: user.email),
        headers: plunk_headers(secret: old_secret),
      )
      expect(response.status).to eq(401)

      post_plunk(
        "complaint",
        plunk_payload("synthetic-email-complaint", email: user.email),
        headers: plunk_headers(secret: new_secret),
      )
      expect(response.status).to eq(200)
    end

    it "works without a browser session or CSRF token on a login-required forum" do
      SiteSetting.login_required = true
      post_plunk("complaint", complaint)

      expect(response.status).to eq(200)
      expect(response.headers["Location"]).to be_nil
      expect(email_off?(user)).to eq(true)
    end

    it "keeps CSRF protection on for the rest of the site" do
      ActionController::Base.allow_forgery_protection = true
      sign_in(Fabricate(:admin))
      put "/admin/site_settings/title.json", params: { title: "changed" }
      expect(response.status).to eq(403)
    ensure
      ActionController::Base.allow_forgery_protection = false
    end

    it "answers non-POST methods with 405" do
      get "/discourse-plunk/webhooks/complaint"
      expect(response.status).to eq(405)
      expect(response.headers["Allow"]).to eq("POST")

      put "/discourse-plunk/webhooks/bounce", params: complaint.to_json, headers: plunk_headers
      expect(response.status).to eq(405)
      expect(DiscoursePlunk::FeedbackEvent.count).to eq(0)
    end

    it "returns 503 in read-only mode without storing anything" do
      Discourse.enable_readonly_mode
      post_plunk("complaint", complaint)

      expect(response.status).to eq(503)
      expect(DiscoursePlunk::FeedbackEvent.count).to eq(0)
    ensure
      Discourse.disable_readonly_mode
    end
  end

  describe "request validation" do
    it "requires a JSON content type" do
      post "/discourse-plunk/webhooks/complaint",
           params: complaint.to_json,
           headers: plunk_headers.merge("CONTENT_TYPE" => "text/plain")

      expect(response.status).to eq(415)
    end

    it "rejects bodies over 64 KiB" do
      complaint["contact"]["data"] = { "padding" => "x" * 70.kilobytes }
      post_plunk("complaint", complaint)

      expect(response.status).to eq(413)
      expect(DiscoursePlunk::FeedbackEvent.count).to eq(0)
      expect(email_off?(user)).to eq(false)
    end

    it "rejects invalid JSON" do
      post_plunk("complaint", "{not json")
      expect(response.status).to eq(400)
      expect(response.parsed_body["error"]).to eq("invalid_json")
    end

    it "rejects invalid UTF-8" do
      post_plunk("complaint", complaint.to_json.sub("TRANSACTIONAL", "TRANS\xFFACTIONAL".b))
      expect(response.status).to eq(400)
    end

    it "rejects a JSON array body" do
      post_plunk("complaint", [complaint])
      expect(response.status).to eq(422)
      expect(DiscoursePlunk::FeedbackEvent.count).to eq(0)
    end

    it "rejects a missing contact email with a useful error and no mutation" do
      complaint["contact"].delete("email")
      post_plunk("complaint", complaint)

      expect(response.status).to eq(422)
      expect(response.parsed_body["details"]).to include("contact.email is required")
      expect(DiscoursePlunk::FeedbackEvent.count).to eq(0)
      expect(email_off?(user)).to eq(false)
    end

    it "rejects a missing execution id" do
      complaint["execution"].delete("id")
      post_plunk("complaint", complaint)

      expect(response.status).to eq(422)
      expect(response.parsed_body["details"]).to include("execution.id is required")
    end

    it "rejects a malformed workflow id" do
      complaint["workflow"]["id"] = 12_345
      post_plunk("complaint", complaint)

      expect(response.status).to eq(422)
      expect(response.parsed_body["details"]).to include("workflow.id must be a string")
    end

    it "rejects an over-long execution id" do
      complaint["execution"]["id"] = "e" * 192
      post_plunk("complaint", complaint)

      expect(response.status).to eq(422)
    end

    it "rejects the string \"false\" as contact.subscribed" do
      complaint["contact"]["subscribed"] = "false"
      post_plunk("complaint", complaint)

      expect(response.status).to eq(422)
      expect(response.parsed_body["details"]).to include("contact.subscribed must be a boolean")
    end

    it "requires the event object on complaint and bounce routes" do
      complaint.delete("event")
      post_plunk("complaint", complaint)
      expect(response.status).to eq(422)
    end
  end

  describe "the default-body fixtures" do
    it "processes the unsubscribe fixture, including an empty event object" do
      payload = plunk_payload("synthetic-contact-unsubscribed", email: user.email)
      expect(payload["event"]).to eq({})

      post_plunk("unsubscribe", payload)

      expect(response.status).to eq(200)
      expect(response.parsed_body).to include("status" => "processed")
      event = DiscoursePlunk::FeedbackEvent.last
      expect(event.kind).to eq("contact.unsubscribed")
      expect(event.score_state).to eq("not_applicable")
      expect(email_off?(user)).to eq(true)
      expect(user.user_stat.reload.bounce_score).to eq(0)
    end

    it "processes an unsubscribe whose event is null" do
      payload = plunk_payload("synthetic-contact-unsubscribed", email: user.email)
      payload["event"] = nil
      post_plunk("unsubscribe", payload)

      expect(response.status).to eq(200)
      expect(email_off?(user)).to eq(true)
    end

    it "processes the complaint fixture" do
      post_plunk("complaint", complaint)

      expect(response.status).to eq(200)
      event = DiscoursePlunk::FeedbackEvent.last
      expect(event).to have_attributes(
        kind: "email.complaint",
        recipient: "plunk-test@example.com",
        workflow_id: "wf_test_complaint",
        plunk_email_id: "test-plunk-email-id",
        provider_message_id: "test-provider-message-id",
        status: "processed",
        user_id: user.id,
      )
      expect(event.occurred_at).to eq_time(Time.utc(2026, 9, 30, 12))
      expect(event.execution_started_at).to eq_time(Time.utc(2026, 9, 30, 12))
      expect(user.user_stat.reload.bounce_score).to eq(SiteSetting.hard_bounce_score)
      expect(email_off?(user)).to eq(true)
    end

    it "processes the bounce fixtures" do
      %w[permanent transient undetermined].each do |type|
        post_plunk("bounce", plunk_payload("synthetic-email-bounce-#{type}", email: user.email))
        expect(response.status).to eq(200)
      end

      expect(DiscoursePlunk::FeedbackEvent.order(:id).pluck(:bounce_classification)).to eq(
        %w[permanent transient unknown],
      )
      expect(email_off?(user)).to eq(true)
    end

    it "accepts sparse metadata: a complaint with an empty event object" do
      payload = plunk_payload("synthetic-email-complaint", email: user.email)
      payload["event"] = {}
      post_plunk("complaint", payload)

      expect(response.status).to eq(200)
      event = DiscoursePlunk::FeedbackEvent.last
      expect(event.provider_message_id).to be_nil
      expect(event.correlation).to eq("no_message_identifier")
      expect(email_off?(user)).to eq(true)
    end

    it "uses the route, not the payload, to decide the event type" do
      # A complaint body posted to the unsubscribe route is an unsubscribe.
      post_plunk("unsubscribe", complaint)

      event = DiscoursePlunk::FeedbackEvent.last
      expect(event.kind).to eq("contact.unsubscribed")
      expect(user.user_stat.reload.bounce_score).to eq(0)
    end

    it "does not store the subject, sender or contact data" do
      post_plunk("complaint", complaint)

      row = DB.query_hash("SELECT * FROM discourse_plunk_feedback_events").first.to_json
      expect(row).not_to include("Synthetic subject")
      expect(row).not_to include("forum@example.com")
      expect(row).not_to include("Synthetic Forum")
    end
  end

  describe "responses" do
    it "returns no account details to the caller, matched or not" do
      post_plunk("complaint", complaint)
      matched = response.parsed_body

      post_plunk(
        "complaint",
        plunk_payload("synthetic-email-complaint", email: "nobody@example.com"),
      )
      unmatched = response.parsed_body

      expect(matched.keys).to contain_exactly("status", "receipt_id")
      expect(unmatched.keys).to contain_exactly("status", "receipt_id")
      expect(matched["status"]).to eq(unmatched["status"])
      expect(response.body).not_to include(user.username)
      expect(response.body).not_to include("nobody@example.com")
    end

    it "reports a replay as a duplicate" do
      post_plunk("complaint", complaint)
      post_plunk("complaint", complaint)

      expect(response.status).to eq(200)
      expect(response.parsed_body["status"]).to eq("duplicate")
      expect(DiscoursePlunk::FeedbackEvent.count).to eq(1)
      expect(DiscoursePlunk::FeedbackEvent.last.delivery_count).to eq(2)
    end

    it "answers 409 when a delivery identity is reused for different feedback" do
      post_plunk("complaint", complaint)
      other = complaint.deep_dup
      other["contact"]["email"] = "someone-else@example.com"
      post_plunk("complaint", other)

      expect(response.status).to eq(409)
      expect(DiscoursePlunk::FeedbackEvent.count).to eq(1)
      expect(DiscoursePlunk::FeedbackEvent.last.identity_conflict_count).to eq(1)
    end

    it "answers 202 accepted when a phase fails and the retry worker is running" do
      Jobs.stubs(:last_job_performed_at).returns(1.minute.ago)
      Email::Receiver.stubs(:update_bounce_score).raises(ActiveRecord::StatementInvalid, "boom")

      post_plunk("complaint", complaint)

      expect(response.status).to eq(202)
      expect(response.parsed_body["status"]).to eq("accepted")
      # The preference change was committed before scoring failed.
      expect(email_off?(user)).to eq(true)
    end

    it "answers 503 when a phase fails and nothing would retry it" do
      Jobs.stubs(:last_job_performed_at).returns(nil)
      Email::Receiver.stubs(:update_bounce_score).raises(ActiveRecord::StatementInvalid, "boom")

      post_plunk("complaint", complaint)

      expect(response.status).to eq(503)
      expect(response.parsed_body["status"]).to eq("failed")
      expect(DiscoursePlunk::FeedbackEvent.last.status).to eq("failed")
    end

    it "answers 500 when a receipt cannot be stored" do
      DiscoursePlunk::FeedbackEvent.stubs(:insert_all).raises(
        ActiveRecord::StatementInvalid,
        "down",
      )

      post_plunk("complaint", complaint)

      expect(response.status).to eq(500)
      expect(email_off?(user)).to eq(false)
    end
  end

  describe "secret handling" do
    it "never echoes the secret or the recipient in responses" do
      [
        -> { post_plunk("complaint", complaint) },
        -> { post_plunk("complaint", complaint, headers: plunk_headers(secret: "wrong")) },
        -> { post_plunk("complaint", "{bad") },
      ].each do |request|
        request.call
        expect(response.body).not_to include(plunk_secret)
      end
    end

    it "filters the payload and the secret settings from Rails parameter logging" do
      filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
      filtered = filter.filter(complaint)

      expect(filtered["contact"]["email"]).to eq("[FILTERED]")
      expect(filtered["event"]["messageId"]).to eq("[FILTERED]")
      expect(filtered["workflow"]["id"]).to eq("[FILTERED]")

      expect(filter.filter("plunk_feedback_webhook_secret" => "s3cret")).to eq(
        "plunk_feedback_webhook_secret" => "[FILTERED]",
      )
      expect(
        filter.filter(
          "settings" => {
            "plunk_feedback_webhook_previous_secret" => {
              "value" => "x",
            },
          },
        ),
      ).to eq("settings" => { "plunk_feedback_webhook_previous_secret" => "[FILTERED]" })
      # Ordinary parameters elsewhere are untouched.
      expect(filter.filter("title" => "hello", "contact_email" => "a@b.c")).to eq(
        "title" => "hello",
        "contact_email" => "a@b.c",
      )
    end

    it "never writes the secret or the recipient to the Rails log" do
      # A real Logger at production's INFO level. (DEBUG adds ActiveRecord's
      # SQL echo, which quotes bind values — including addresses — for every
      # query in core too; production does not log at DEBUG.)
      io = StringIO.new
      logger = ActiveSupport::Logger.new(io, level: :info)
      Rails.logger.broadcast_to(logger)
      begin
        post_plunk("complaint", complaint)
        post_plunk("complaint", complaint, headers: plunk_headers(secret: "nope"))
        Email::Receiver.stubs(:update_bounce_score).raises(ActiveRecord::StatementInvalid, "boom")
        post_plunk(
          "complaint",
          plunk_payload(
            "synthetic-email-complaint",
            email: user.email,
            event: {
              emailId: "other",
            },
          ),
        )
      ensure
        Rails.logger.stop_broadcasting_to(logger)
      end
      log = io.string

      # The plugin's own log lines are captured (the failure above logs one)...
      expect(log).to include("discourse-plunk: receipt")
      # ...and neither the secret nor the address ever appears.
      expect(log).not_to include(plunk_secret)
      expect(log).not_to include("plunk-test@example.com")

      # What Rails' request logger prints as "Parameters:" in production is
      # request.filtered_parameters (its log subscriber is detached in tests).
      expect(request.filtered_parameters.to_s).not_to include("plunk-test@example.com")
      expect(request.filtered_parameters.to_s).not_to include("test-provider-message-id")
      expect(request.filtered_parameters.dig("contact", "email")).to eq("[FILTERED]")
    end
  end

  it "makes no outbound HTTP requests" do
    post_plunk("complaint", complaint)
    post_plunk("bounce", plunk_payload("synthetic-email-bounce-permanent", email: user.email))

    expect(response.status).to eq(200)
    expect(WebMock::RequestRegistry.instance.requested_signatures.hash).to be_empty
  end
end
