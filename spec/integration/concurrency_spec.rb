# frozen_string_literal: true

require_relative "../support/plunk_helpers"

# Real concurrency: two threads, two database connections, no wrapping test
# transaction, so the unique index and row locks do the work they do in
# production. (The test database pool has two connections.)
RSpec.describe "Plunk feedback under concurrent delivery" do
  self.use_transactional_tests = false

  let!(:user) { Fabricate(:user, email: "race-#{SecureRandom.hex(4)}@example.com") }

  before do
    enable_plunk!
    SiteSetting.bounce_score_threshold = 1000
  end

  after do
    DiscoursePlunk::FeedbackEvent.where(recipient: user.email).delete_all
    UserHistory.where(target_user_id: user.id).delete_all
    user.reload.destroy!
  end

  # Runs each block in its own thread and connection, released together.
  def race(*blocks)
    ActiveRecord::Base.connection_pool.release_connection
    gate = Queue.new
    threads =
      blocks.map do |block|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            gate.pop
            block.call
          end
        end
      end
    blocks.size.times { gate << true }
    threads.map(&:value)
  end

  def complaint(execution_id)
    plunk_payload("synthetic-email-complaint", email: user.email, execution_id: execution_id)
  end

  it "stores one receipt and applies one score when the same delivery arrives twice at once" do
    payload = complaint("exec_race_same")

    results =
      race(-> { receive_plunk("complaint", payload) }, -> { receive_plunk("complaint", payload) })

    events = DiscoursePlunk::FeedbackEvent.where(recipient: user.email)
    expect(events.count).to eq(1)
    expect(events.first.delivery_count).to eq(2)
    expect(
      results.count { |r| r.is_a?(DiscoursePlunk::Receiver::Result) && r.status == :duplicate },
    ).to eq(1)
    expect(user.user_stat.reload.bounce_score).to eq(SiteSetting.hard_bounce_score)
    expect(email_off?(user)).to eq(true)
  end

  it "applies one score when two executions of the same complaint are processed at once" do
    race(
      -> { receive_plunk("complaint", complaint("exec_race_a")) },
      -> { receive_plunk("complaint", complaint("exec_race_b")) },
    )

    events = DiscoursePlunk::FeedbackEvent.where(recipient: user.email)
    expect(events.count).to eq(2)
    expect(events.pluck(:status)).to all(eq("processed"))
    expect(events.where(score_state: "done").count).to eq(1)
    expect(events.where(preference_state: "done").count).to eq(1)
    expect(user.user_stat.reload.bounce_score).to eq(SiteSetting.hard_bounce_score)
    expect(
      UserHistory.where(custom_type: "plunk_feedback_email_opt_out", target_user_id: user.id).count,
    ).to eq(1)
  end

  it "keeps both receipts and one score when a complaint and its unsubscribe race" do
    unsubscribe =
      plunk_payload(
        "synthetic-contact-unsubscribed",
        email: user.email,
        execution_id: "exec_race_unsub",
        event: {
          reason: "complaint",
        },
      )

    race(
      -> { receive_plunk("complaint", complaint("exec_race_complaint")) },
      -> { receive_plunk("unsubscribe", unsubscribe) },
    )

    events = DiscoursePlunk::FeedbackEvent.where(recipient: user.email)
    expect(events.count).to eq(2)
    expect(events.pluck(:status)).to all(eq("processed"))
    expect(user.user_stat.reload.bounce_score).to eq(SiteSetting.hard_bounce_score)
    expect(email_off?(user)).to eq(true)
  end
end
