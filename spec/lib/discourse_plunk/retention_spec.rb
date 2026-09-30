# frozen_string_literal: true

require_relative "../../support/plunk_helpers"

RSpec.describe DiscoursePlunk::Retention do
  fab!(:user) { Fabricate(:user, email: "member@example.com") }

  before do
    enable_plunk!
    SiteSetting.plunk_feedback_event_retention_days = 30
  end

  def complaint(**opts)
    plunk_payload("synthetic-email-complaint", email: user.email, **opts)
  end

  it "deletes finished history past the retention window and keeps hashed tombstones" do
    old_event = receive_plunk("complaint", complaint(execution_id: "exec_old"))
    old_event.update_columns(received_at: 31.days.ago)
    recent =
      receive_plunk(
        "unsubscribe",
        plunk_payload("synthetic-contact-unsubscribed", email: user.email),
      )

    expect(Jobs::DiscoursePlunkPurgeEvents.new.execute({})).to eq(1)

    expect(DiscoursePlunk::FeedbackEvent.exists?(old_event.id)).to eq(false)
    expect(DiscoursePlunk::FeedbackEvent.exists?(recent.id)).to eq(true)

    tombstones = DiscoursePlunk::Tombstone.all
    expect(tombstones.map(&:key_type)).to contain_exactly("delivery", "feedback")
    expect(tombstones.find_by(key_type: "feedback")).to have_attributes(
      preference_applied: true,
      score_applied: true,
    )
    # Nothing readable is kept: no address, no Plunk identifiers.
    dump = DB.query_hash("SELECT * FROM discourse_plunk_tombstones").to_json
    expect(dump).not_to include("member@example.com")
    expect(dump).not_to include("test-plunk-email-id")
    expect(dump).not_to include("exec_old")
  end

  it "keeps unfinished events regardless of age" do
    Email::Receiver.stubs(:update_bounce_score).raises(ActiveRecord::StatementInvalid, "down")
    event = receive_plunk("complaint", complaint)
    event.update_columns(received_at: 90.days.ago)

    described_class.purge

    expect(DiscoursePlunk::FeedbackEvent.exists?(event.id)).to eq(true)
  end

  it "recognises a replay of a purged delivery instead of treating it as new" do
    payload = complaint(execution_id: "exec_old")
    receive_plunk("complaint", payload).update_columns(received_at: 31.days.ago)
    described_class.purge
    opt_in!(user)

    result = receive_plunk("complaint", payload)

    expect(result.status).to eq(:tombstoned)
    expect(DiscoursePlunk::FeedbackEvent.count).to eq(0)
    expect(user.user_option.reload.email_level).to eq(UserOption.email_level_types[:always])
    expect(user.user_stat.reload.bounce_score).to eq(SiteSetting.hard_bounce_score)
  end

  it "recognises the same complaint arriving through a new execution after its history was purged" do
    receive_plunk("complaint", complaint(execution_id: "exec_old")).update_columns(
      received_at: 31.days.ago,
    )
    described_class.purge
    opt_in!(user)

    event = receive_plunk("complaint", complaint(execution_id: "exec_new"))

    expect(event).to have_attributes(
      status: "processed",
      preference_state: "skipped",
      score_state: "skipped",
      outcome: "duplicate_feedback",
    )
    expect(user.user_option.reload.email_level).to eq(UserOption.email_level_types[:always])
    expect(user.user_stat.reload.bounce_score).to eq(SiteSetting.hard_bounce_score)
  end
end
