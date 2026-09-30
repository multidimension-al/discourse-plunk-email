# frozen_string_literal: true

require_relative "../../support/plunk_helpers"

RSpec.describe DiscoursePlunk::Backfill do
  fab!(:user) { Fabricate(:user, email: "historic@example.com") }

  let(:file) { Tempfile.new(%w[plunk-backfill .json]) }

  before { enable_plunk! }
  after { file.close! }

  def write(records)
    file.write(records.to_json)
    file.flush
    file.path
  end

  def historic_complaint(execution_id, email: user.email)
    plunk_payload(
      "synthetic-email-complaint",
      email: email,
      workflow_id: "backfill-2026-09",
      execution_id: execution_id,
    )
  end

  it "replays known historical feedback through the same validation and processor" do
    path =
      write(
        [
          historic_complaint("backfill-001"),
          historic_complaint("backfill-001"), # listed twice by mistake
          historic_complaint("backfill-002", email: "not-a-member@example.com"),
          { "contact" => { "email" => "broken" } },
        ],
      )

    outcomes = described_class.run("complaint", path)

    expect(outcomes.map(&:status)).to eq(%w[processed duplicate unmatched invalid])
    expect(outcomes.last.detail).to include("contact.email is not a valid email address")
    expect(DiscoursePlunk::FeedbackEvent.pluck(:source).uniq).to eq(["backfill"])
    expect(email_off?(user)).to eq(true)
    expect(user.user_stat.reload.bounce_score).to eq(SiteSetting.hard_bounce_score)
  end

  it "recognises a later live callback for the same Plunk email as the same complaint" do
    described_class.run("complaint", write([historic_complaint("backfill-003")]))

    live = receive_plunk("complaint", plunk_payload("synthetic-email-complaint", email: user.email))

    expect(live.outcome).to eq("duplicate_feedback")
    expect(user.user_stat.reload.bounce_score).to eq(SiteSetting.hard_bounce_score)
  end

  it "refuses to run while the plugin is disabled" do
    SiteSetting.plunk_feedback_enabled = false
    expect { described_class.run("complaint", write([historic_complaint("x")])) }.to raise_error(
      Discourse::InvalidAccess,
    )
    expect(DiscoursePlunk::FeedbackEvent.count).to eq(0)
  end

  describe "rake plunk_feedback:replay" do
    before do
      Rake::Task.clear
      silence_warnings { Discourse::Application.load_tasks }
      # Discourse registers plugin task files with Rake.add_rakelib, which the
      # real `rake` command imports (see `bin/rake -T plunk`); load it here.
      Rake.load_rakefile(File.expand_path("../../../lib/tasks/discourse_plunk.rake", __dir__))
    end

    it "is available and reports each record" do
      path = write([historic_complaint("backfill-rake-1")])

      output = capture_stdout { Rake::Task["plunk_feedback:replay"].invoke("complaint", path) }

      expect(output).to include("record 0 | processed | receipt #")
      expect(output).not_to include(user.email)
      expect(email_off?(user)).to eq(true)
    end
  end

  describe "rollback" do
    it "leaves applied preferences exactly as they are when the plugin is disabled" do
      receive_plunk("complaint", plunk_payload("synthetic-email-complaint", email: user.email))
      SiteSetting.plunk_feedback_enabled = false
      Jobs::DiscoursePlunkRecoverEvents.new.execute({})
      Jobs::DiscoursePlunkPurgeEvents.new.execute({})

      expect(email_off?(user)).to eq(true)
    end
  end
end
