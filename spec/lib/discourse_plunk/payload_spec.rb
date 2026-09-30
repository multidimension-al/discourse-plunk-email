# frozen_string_literal: true

require_relative "../../support/plunk_helpers"

RSpec.describe DiscoursePlunk::Payload do
  def parse(kind, payload)
    described_class.parse(kind, payload, received_at: Time.utc(2026, 9, 30, 13))
  end

  def bounce(event)
    payload = plunk_fixture("synthetic-email-bounce-permanent")
    payload["event"] = event
    parse("email.bounce", payload)
  end

  it "normalises the complaint fixture into the internal event" do
    event = parse("email.complaint", plunk_fixture("synthetic-email-complaint"))

    expect(event.to_h).to eq(
      kind: "email.complaint",
      recipient: "plunk-test@example.com",
      contact_subscribed: false,
      workflow_id: "wf_test_complaint",
      workflow_name: "Discourse complaint feedback",
      execution_id: "exec_test_001",
      execution_started_at: Time.utc(2026, 9, 30, 12),
      plunk_email_id: "test-plunk-email-id",
      provider_message_id: "test-provider-message-id",
      bounce_classification: nil,
      bounce_type: nil,
      unsubscribe_reason: nil,
      source_type: "TRANSACTIONAL",
      occurred_at: Time.utc(2026, 9, 30, 12),
      received_at: Time.utc(2026, 9, 30, 13),
    )
  end

  it "keeps the workflow start separate from the provider event time" do
    payload = plunk_fixture("synthetic-email-complaint")
    payload["event"].delete("complainedAt")

    event = parse("email.complaint", payload)

    expect(event.execution_started_at).to eq_time(Time.utc(2026, 9, 30, 12))
    expect(event.occurred_at).to be_nil
  end

  describe "bounce classification" do
    it "trusts only explicit values" do
      expect(bounce("bounceType" => "Permanent").bounce_classification).to eq("permanent")
      expect(bounce("bounceType" => "Transient").bounce_classification).to eq("transient")
      expect(bounce("transientBounce" => true).bounce_classification).to eq("transient")
      expect(bounce("bounceType" => "Undetermined").bounce_classification).to eq("unknown")
      expect(bounce("bounceType" => "Mystery").bounce_classification).to eq("unknown")
      expect(bounce({}).bounce_classification).to eq("unknown")
    end

    it "does not promote a self-contradictory bounce to permanent" do
      event = bounce("bounceType" => "Permanent", "transientBounce" => true)
      expect(event.bounce_classification).to eq("unknown")
    end

    it "requires transientBounce to be a real boolean" do
      expect { bounce("transientBounce" => "true") }.to raise_error(
        described_class::Invalid,
        /event.transientBounce must be a boolean/,
      )
    end
  end

  it "rejects a non-ISO timestamp" do
    payload = plunk_fixture("synthetic-email-complaint")
    payload["event"]["complainedAt"] = "yesterday"

    expect { parse("email.complaint", payload) }.to raise_error(
      described_class::Invalid,
      /complainedAt must be an ISO 8601 timestamp/,
    )
  end

  it "rejects identifiers with whitespace or control characters" do
    payload = plunk_fixture("synthetic-email-complaint")
    payload["execution"]["id"] = "exec 1"
    expect { parse("email.complaint", payload) }.to raise_error(described_class::Invalid)

    payload["execution"]["id"] = "exec\u0000"
    expect { parse("email.complaint", payload) }.to raise_error(described_class::Invalid)
  end

  it "rejects an invalid address" do
    payload = plunk_fixture("synthetic-email-complaint")
    payload["contact"]["email"] = "not an address"

    expect { parse("email.complaint", payload) }.to raise_error(
      described_class::Invalid,
      /contact.email is not a valid email address/,
    )
  end

  it "collects every problem at once" do
    expect { parse("email.bounce", { "contact" => [], "workflow" => {} }) }.to raise_error(
      described_class::Invalid,
    ) do |error|
      expect(error.errors).to include(
        "contact must be an object",
        "workflow.id is required",
        "execution is required",
        "event is required",
      )
    end
  end

  describe "identities" do
    let(:complaint) { parse("email.complaint", plunk_fixture("synthetic-email-complaint")) }

    it "derives the delivery identity from route, workflow and execution only" do
      other_route = parse("contact.unsubscribed", plunk_fixture("synthetic-email-complaint"))

      expect(complaint.delivery_digest).not_to eq(other_route.delivery_digest)
      expect(complaint.delivery_digest).to eq(
        described_class.digest("delivery", "email.complaint", "wf_test_complaint", "exec_test_001"),
      )
    end

    it "gives unsubscribes no feedback identity" do
      expect(
        other = parse("contact.unsubscribed", plunk_fixture("synthetic-contact-unsubscribed")),
      ).to be
      expect(other.feedback_digest).to be_nil
    end

    it "prefers Plunk's email id and falls back to the provider message id" do
      without_email_id = plunk_fixture("synthetic-email-complaint")
      without_email_id["event"].delete("emailId")
      neither = plunk_fixture("synthetic-email-complaint")
      neither["event"].delete("emailId")
      neither["event"].delete("messageId")

      expect(complaint.feedback_digest).to be_present
      expect(parse("email.complaint", without_email_id).feedback_digest).to be_present
      expect(parse("email.complaint", without_email_id).feedback_digest).not_to eq(
        complaint.feedback_digest,
      )
      expect(parse("email.complaint", neither).feedback_digest).to be_nil
    end

    it "never uses processing time or a random value as an identity" do
      later = described_class.parse("email.complaint", plunk_fixture("synthetic-email-complaint"))

      expect(later.delivery_digest).to eq(complaint.delivery_digest)
      expect(later.identity_digest).to eq(complaint.identity_digest)
      expect(later.feedback_digest).to eq(complaint.feedback_digest)
    end
  end
end
