# frozen_string_literal: true

require_relative "../support/plunk_helpers"

RSpec.describe DiscoursePlunk::AdminFeedbackController do
  fab!(:admin)
  fab!(:moderator)
  fab!(:member) { Fabricate(:user, email: "member@example.com") }

  let(:base) { "/admin/plugins/discourse-plunk-email/feedback" }

  before { enable_plunk! }

  describe "access" do
    it "is refused to anonymous visitors, members and moderators" do
      get "#{base}/status.json"
      expect(response.status).to eq(404)

      [member, moderator].each do |user|
        sign_in(user)
        get "#{base}/status.json"
        expect(response.status).to eq(404)
        get "#{base}/events.json"
        expect(response.status).to eq(404)
        post "#{base}/events/1/reprocess.json"
        expect(response.status).to eq(404)
      end
    end

    it "keeps CSRF protection on reprocessing" do
      event =
        receive_plunk(
          "unsubscribe",
          plunk_payload("synthetic-contact-unsubscribed", email: member.email),
        )
      sign_in(admin)
      ActionController::Base.allow_forgery_protection = true

      post "#{base}/events/#{event.id}/reprocess.json"

      expect(response.status).to eq(403)
    ensure
      ActionController::Base.allow_forgery_protection = false
    end
  end

  describe "#status" do
    before { sign_in(admin) }

    it "shows absolute webhook URLs, configuration state and counts without the secret" do
      receive_plunk("complaint", plunk_payload("synthetic-email-complaint", email: member.email))
      receive_plunk(
        "complaint",
        plunk_payload("synthetic-email-complaint", email: "nobody@example.com"),
      )
      SiteSetting.plunk_feedback_webhook_previous_secret = SecureRandom.base64(48)

      get "#{base}/status.json"

      expect(response.status).to eq(200)
      body = response.parsed_body
      expect(body["webhooks"]).to contain_exactly(
        {
          "trigger" => "contact.unsubscribed",
          "route" => "unsubscribe",
          "url" => "#{Discourse.base_url}/discourse-plunk/webhooks/unsubscribe",
        },
        {
          "trigger" => "email.complaint",
          "route" => "complaint",
          "url" => "#{Discourse.base_url}/discourse-plunk/webhooks/complaint",
        },
        {
          "trigger" => "email.bounce",
          "route" => "bounce",
          "url" => "#{Discourse.base_url}/discourse-plunk/webhooks/bounce",
        },
      )
      expect(body).to include(
        "enabled" => true,
        "secret_configured" => true,
        "previous_secret_configured" => true,
      )
      expect(body["counts"]).to include("processed" => 1, "unmatched" => 1, "failed" => 0)
      expect(body["optional_preferences"]).to include("email_level", "chat_email_frequency")
      expect(body["last_received_at"]).to be_present
      expect(body["last_processed_at"]).to be_present
      expect(response.body).not_to include(SiteSetting.plunk_feedback_webhook_secret)
      expect(response.body).not_to include(SiteSetting.plunk_feedback_webhook_previous_secret)
    end

    it "includes an installation subpath in the webhook URLs" do
      set_subfolder "/forum"

      get "#{base}/status.json"

      expect(response.parsed_body["webhooks"].map { |w| w["url"] }).to all(
        start_with("#{Discourse.base_url_no_prefix}/forum/discourse-plunk/webhooks/"),
      )
    end

    it "stays available while the receiver is disabled (for diagnosis and rollback)" do
      SiteSetting.plunk_feedback_enabled = false
      get "#{base}/status.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["enabled"]).to eq(false)
    end
  end

  describe "#index and #show" do
    before { sign_in(admin) }

    fab!(:other) { Fabricate(:user, email: "other@example.com") }

    let!(:complaint_event) do
      receive_plunk("complaint", plunk_payload("synthetic-email-complaint", email: member.email))
    end
    let!(:bounce_event) do
      receive_plunk(
        "bounce",
        plunk_payload(
          "synthetic-email-bounce-permanent",
          email: other.email,
          execution_id: "exec_findme_42",
        ),
      )
    end
    let!(:unknown_event) do
      receive_plunk(
        "unsubscribe",
        plunk_payload("synthetic-contact-unsubscribed", email: "ghost@example.com"),
      )
    end

    it "lists events newest first" do
      get "#{base}/events.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["events"].map { |e| e["id"] }).to eq(
        [unknown_event.id, bounce_event.id, complaint_event.id],
      )
      expect(response.parsed_body["total"]).to eq(3)
    end

    it "searches by address fragment, username, receipt number and identifiers" do
      {
        "member@" => complaint_event,
        other.username => bounce_event,
        "##{unknown_event.id}" => unknown_event,
        "exec_findme_42" => bounce_event,
        "test-plunk-email-id" => complaint_event,
      }.each do |query, expected|
        get "#{base}/events.json", params: { q: query }
        expect(response.parsed_body["events"].map { |e| e["id"] }).to eq([expected.id]), query
      end
    end

    it "filters by status and event kind" do
      get "#{base}/events.json", params: { status: "unmatched" }
      expect(response.parsed_body["events"].map { |e| e["id"] }).to eq([unknown_event.id])

      get "#{base}/events.json", params: { kind: "email.bounce" }
      expect(response.parsed_body["events"].map { |e| e["id"] }).to eq([bounce_event.id])
    end

    it "shows the full detail of one event" do
      get "#{base}/events/#{complaint_event.id}.json"

      event = response.parsed_body["event"]
      expect(event).to include(
        "kind" => "email.complaint",
        "recipient" => "member@example.com",
        "user_id" => member.id,
        "username" => member.username,
        "workflow_id" => "wf_test_complaint",
        "plunk_email_id" => "test-plunk-email-id",
        "provider_message_id" => "test-provider-message-id",
        "match_method" => "primary_email",
        "correlation" => "user_matched_message_unmatched",
        "preference_state" => "done",
        "score_state" => "done",
        "score_effect" => "hard_bounce_score",
        "attempts" => 1,
      )
      expect(event["preference_changes"]["changes"]).to be_present
    end
  end

  describe "#reprocess" do
    fab!(:user) { Fabricate(:user, email: "retry@example.com") }

    before do
      sign_in(admin)
      opt_in!(user)
    end

    it "finishes a failed event through the same idempotent service" do
      Email::Receiver.stubs(:update_bounce_score).raises(ActiveRecord::StatementInvalid, "down")
      event =
        receive_plunk("complaint", plunk_payload("synthetic-email-complaint", email: user.email))
      expect(event.status).to eq("failed")
      Email::Receiver.unstub(:update_bounce_score)

      post "#{base}/events/#{event.id}/reprocess.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["event"]).to include("status" => "processed", "attempts" => 2)
      expect(user.user_stat.reload.bounce_score).to eq(SiteSetting.hard_bounce_score)

      # Reprocessing a finished event changes nothing, even after an opt-in.
      opt_in!(user)
      post "#{base}/events/#{event.id}/reprocess.json"
      expect(response.parsed_body["event"]["attempts"]).to eq(2)
      expect(user.user_stat.reload.bounce_score).to eq(SiteSetting.hard_bounce_score)
      expect(user.user_option.reload.email_level).to eq(UserOption.email_level_types[:always])
    end

    it "re-resolves an unmatched event when an administrator asks" do
      event =
        receive_plunk(
          "unsubscribe",
          plunk_payload("synthetic-contact-unsubscribed", email: "later@example.com"),
        )
      expect(event.status).to eq("unmatched")
      Fabricate(:secondary_email, user: user, email: "later@example.com")

      post "#{base}/events/#{event.id}/reprocess.json"

      expect(response.parsed_body["event"]).to include(
        "status" => "processed",
        "user_id" => user.id,
      )
      expect(email_off?(user)).to eq(true)
    end

    it "refuses while the plugin is disabled" do
      event =
        receive_plunk(
          "unsubscribe",
          plunk_payload("synthetic-contact-unsubscribed", email: user.email),
        )
      SiteSetting.plunk_feedback_enabled = false

      post "#{base}/events/#{event.id}/reprocess.json"

      expect(response.status).to eq(422)
    end
  end
end
