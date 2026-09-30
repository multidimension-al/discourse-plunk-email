# frozen_string_literal: true

require_relative "../../support/plunk_helpers"

RSpec.describe DiscoursePlunk::Processor do
  fab!(:user) { Fabricate(:user, email: "member@example.com") }
  fab!(:bystander) { Fabricate(:user, email: "bystander@example.com") }

  let(:never) { UserOption.email_level_types[:never] }

  before do
    enable_plunk!
    opt_in!(user)
    opt_in!(bystander)
    user.user_option.update!(policy_email_frequency: "always")
  end

  def complaint(email: user.email, **opts)
    plunk_payload("synthetic-email-complaint", email: email, **opts)
  end

  def bounce(type, email: user.email, **opts)
    plunk_payload("synthetic-email-bounce-#{type}", email: email, **opts)
  end

  def unsubscribe(email: user.email, **opts)
    plunk_payload("synthetic-contact-unsubscribed", email: email, **opts)
  end

  def bounce_score(u = user)
    u.user_stat.reload.bounce_score
  end

  def expect_all_optional_email_off(u = user)
    option = u.user_option.reload
    expect(option.unsubscribed_from_all?).to eq(true)
    expect(option.email_level).to eq(never)
    expect(option.email_messages_level).to eq(never)
    expect(option.email_digests).to eq(false)
    expect(option.mailing_list_mode).to eq(false)
    expect(option.digest_after_minutes).to eq(0)
    expect(option.chat_email_frequency).to eq("never")
    expect(option.policy_email_frequency).to eq("never")
  end

  def expect_untouched(u)
    option = u.user_option.reload
    expect(option.email_level).to eq(UserOption.email_level_types[:always])
    expect(option.email_digests).to eq(true)
    expect(option.chat_email_frequency).to eq("when_away")
    expect(u.user_stat.reload.bounce_score).to eq(0)
  end

  describe "the owner's policy for each event" do
    it "complaint: every optional email off, the hard-bounce score once, complaint classification kept" do
      event = receive_plunk("complaint", complaint)

      expect(event).to have_attributes(
        status: "processed",
        outcome: "applied",
        kind: "email.complaint",
        preference_state: "done",
        score_state: "done",
        score_effect: "hard_bounce_score",
        score_delta: SiteSetting.hard_bounce_score,
        bounce_classification: nil,
      )
      expect_all_optional_email_off
      expect(bounce_score).to eq(SiteSetting.hard_bounce_score)
      expect_untouched(bystander)
    end

    it "explicit unsubscribe: every optional email off, no bounce score" do
      event = receive_plunk("unsubscribe", unsubscribe)

      expect(event).to have_attributes(status: "processed", score_state: "not_applicable")
      expect_all_optional_email_off
      expect(bounce_score).to eq(0)
    end

    %w[bounce complaint snooze].each do |reason|
      it "unsubscribe with reason #{reason}: no bounce score, reason recorded" do
        event = receive_plunk("unsubscribe", unsubscribe(event: { reason: reason }))

        expect(event.unsubscribe_reason).to eq(reason)
        expect(event.score_state).to eq("not_applicable")
        expect_all_optional_email_off
        expect(bounce_score).to eq(0)
      end
    end

    it "permanent bounce: every optional email off, the hard-bounce score once" do
      event = receive_plunk("bounce", bounce("permanent"))

      expect(event).to have_attributes(
        bounce_classification: "permanent",
        score_effect: "hard_bounce_score",
      )
      expect_all_optional_email_off
      expect(bounce_score).to eq(SiteSetting.hard_bounce_score)
    end

    it "transient bounce: every optional email off, the soft-bounce score, still labelled transient" do
      event = receive_plunk("bounce", bounce("transient"))

      expect(event).to have_attributes(
        bounce_classification: "transient",
        bounce_type: "Transient",
        score_effect: "soft_bounce_score",
      )
      expect_all_optional_email_off
      expect(bounce_score).to eq(SiteSetting.soft_bounce_score)
    end

    it "undetermined bounce: every optional email off, classified unknown, soft score, no invented SMTP code" do
      log =
        Fabricate(
          :email_log,
          user: user,
          to_address: user.email,
          message_id: "test-provider-message-id-bounce-3",
        )
      event = receive_plunk("bounce", bounce("undetermined"))

      expect(event).to have_attributes(
        bounce_classification: "unknown",
        bounce_type: "Undetermined",
        score_effect: "soft_bounce_score",
      )
      expect_all_optional_email_off
      expect(bounce_score).to eq(SiteSetting.soft_bounce_score)
      expect(log.reload.bounced).to eq(true)
      expect(log.bounce_error_code).to be_nil
    end

    it "bounce with no classification at all: unknown" do
      payload = bounce("permanent")
      payload["event"].delete("bounceType")
      event = receive_plunk("bounce", payload)

      expect(event.bounce_classification).to eq("unknown")
      expect(event.score_effect).to eq("soft_bounce_score")
      expect_all_optional_email_off
    end

    it "ignores contact.subscribed=true: the snapshot never overrides a complaint" do
      payload = complaint
      payload["contact"]["subscribed"] = true
      receive_plunk("complaint", payload)

      expect_all_optional_email_off
    end
  end

  describe "native preferences" do
    it "records exactly what changed and writes one staff-history entry" do
      event = receive_plunk("complaint", complaint)

      changes = event.preference_changes["changes"]
      expect(changes["email_level"]).to eq(%w[always never])
      expect(changes["email_digests"]).to eq([true, false])
      expect(changes["digest_after_minutes"]).to eq([10_080, 0])
      expect(changes["chat_email_frequency"]).to eq(%w[when_away never])
      expect(event.preference_changes["strategies"]).to include(
        "EmailControllerHelper::DigestEmailUnsubscriber",
      )

      history = UserHistory.where(custom_type: "plunk_feedback_email_opt_out")
      expect(history.count).to eq(1)
      expect(history.first).to have_attributes(
        target_user_id: user.id,
        acting_user_id: Discourse.system_user.id,
      )
      expect(history.first.details).to include("email_level: always → never")
      expect(history.first.details).not_to include(user.email)
    end

    it "does not create or expose an unsubscribe key" do
      expect { receive_plunk("complaint", complaint) }.not_to change { UnsubscribeKey.count }
    end

    it "leaves everything that is not an optional-email switch alone" do
      category = Fabricate(:category)
      topic = Fabricate(:topic)
      group = Fabricate(:group)
      group.add(user)
      Fabricate(:bookmark, user: user)
      CategoryUser.set_notification_level_for_category(
        user,
        CategoryUser.notification_levels[:watching],
        category.id,
      )
      TopicUser.change(
        user.id,
        topic.id,
        notification_level: TopicUser.notification_levels[:watching],
      )
      user.update!(trust_level: TrustLevel[2])
      user.user_option.update!(
        email_in_reply_to: false,
        email_previous_replies: UserOption.previous_replies_type[:always],
        push_notification_level: "all",
        like_notification_frequency: UserOption.like_notification_frequency_type[:always],
        allow_private_messages: true,
      )
      before = user.user_option.reload.attributes

      receive_plunk("complaint", complaint)

      after = user.user_option.reload.attributes
      changed = after.keys.select { |k| before[k] != after[k] }
      expect(changed).to contain_exactly(
        "email_level",
        "email_messages_level",
        "email_digests",
        "digest_after_minutes",
        "chat_email_frequency",
        "policy_email_frequency",
      )
      expect(Bookmark.where(user: user).count).to eq(1)
      expect(GroupUser.exists?(group: group, user: user)).to eq(true)
      expect(
        CategoryUser.find_by(user: user, category: category).notification_level,
      ).to eq(CategoryUser.notification_levels[:watching])
      expect(TopicUser.get(topic, user).notification_level).to eq(
        TopicUser.notification_levels[:watching],
      )
      user.reload
      expect(user.trust_level).to eq(TrustLevel[2])
      expect(user.active).to eq(true)
      expect(user.suspended?).to eq(false)
      expect(user.silenced?).to eq(false)
    end

    it "is a recorded no-op, with no staff-history entry, for a user who had already opted out" do
      receive_plunk("unsubscribe", unsubscribe)
      UserHistory.where(custom_type: "plunk_feedback_email_opt_out").delete_all

      event = receive_plunk("unsubscribe", unsubscribe)

      expect(event.outcome).to eq("already_unsubscribed")
      expect(event.preference_changes["changes"]).to eq({})
      expect(UserHistory.where(custom_type: "plunk_feedback_email_opt_out").count).to eq(0)
    end

    it "uses Chat's own unsubscribe strategy while Chat is enabled" do
      SiteSetting.chat_enabled = true
      event = receive_plunk("complaint", complaint)

      expect(event.preference_changes["strategies"]).to include(
        "EmailControllerHelper::ChatSummaryUnsubscriber",
      )
      expect(user.user_option.reload.chat_email_frequency).to eq("never")
    end

    it "still turns chat summaries off while Chat is installed but disabled" do
      SiteSetting.chat_enabled = false
      event = receive_plunk("complaint", complaint)

      expect(event.preference_changes["strategies"]).to include("chat_email_frequency=never")
      expect(user.user_option.reload.chat_email_frequency).to eq("never")
    end

    it "works on an installation without Chat (or Policy)" do
      DiscoursePlunk::OptionalEmailPreferences.stubs(:installed_extensions).returns([])

      event = receive_plunk("complaint", complaint)

      expect(event.status).to eq("processed")
      expect(event.preference_changes["changes"].keys).not_to include("chat_email_frequency")
      expect(user.user_option.reload.chat_email_frequency).to eq("when_away")
      expect(user.user_option.unsubscribed_from_all?).to eq(true)
    end

    it "falls back to a direct write when a plugin strategy's validations fail" do
      SiteSetting.chat_enabled = true
      user.user_option.update_columns(timezone: "Not/AZone")

      event = receive_plunk("complaint", complaint)

      expect(event.status).to eq("processed")
      expect(event.preference_changes["strategies"]).to include("chat_email_frequency=never")
      expect_all_optional_email_off
    end

    it "never reports success while an optional preference is still on" do
      DiscoursePlunk::OptionalEmailPreferences.any_instance.stubs(:apply_core)

      event = receive_plunk("complaint", complaint)

      expect(event.status).to eq("failed")
      expect(event.preference_state).to eq("failed")
      expect(event.last_error).to include("PostconditionFailed")
      expect(user.user_option.reload.email_level).to eq(UserOption.email_level_types[:always])
      expect(UserHistory.where(custom_type: "plunk_feedback_email_opt_out").count).to eq(0)
    end
  end

  describe "account matching" do
    it "matches a confirmed secondary address" do
      Fabricate(:secondary_email, user: user, email: "alias@example.com")

      event = receive_plunk("complaint", complaint(email: "alias@example.com"))

      expect(event.match_method).to eq("secondary_email")
      expect(event.user_id).to eq(user.id)
      expect_all_optional_email_off
    end

    it "normalises surrounding whitespace and case the way Discourse does" do
      payload = complaint
      payload["contact"]["email"] = "  Member@EXAMPLE.com "

      event = receive_plunk("complaint", payload)

      expect(event.recipient).to eq("member@example.com")
      expect(event.user_id).to eq(user.id)
    end

    it "never strips plus tags or dots to find an account" do
      tagged = Fabricate(:user, email: "first.last+forum@example.com")
      opt_in!(tagged)

      %w[firstlast+forum@example.com first.last@example.com firstlast@example.com].each do |address|
        event = receive_plunk("complaint", complaint(email: address))
        expect(event.status).to eq("unmatched")
      end

      expect_untouched(tagged)
    end

    it "logs an unknown recipient without creating or changing any account, and never retries it" do
      expect {
        event = receive_plunk("complaint", complaint(email: "stranger@example.com"))
        expect(event).to have_attributes(
          status: "unmatched",
          outcome: "unknown_recipient",
          next_attempt_at: nil,
          preference_state: "skipped",
        )
      }.not_to change { User.count }

      expect_untouched(user)
      expect_untouched(bystander)
      expect(DiscoursePlunk::Recovery.due).to be_empty
    end

    it "does not act on an address the user has removed" do
      secondary = Fabricate(:secondary_email, user: user, email: "old-alias@example.com")
      Fabricate(:email_log, user: user, to_address: "old-alias@example.com", message_id: "m-old")
      secondary.destroy!

      event = receive_plunk("complaint", complaint(email: "old-alias@example.com", event: { messageId: "m-old" }))

      expect(event.status).to eq("unmatched")
      expect_untouched(user)
    end

    it "does not suppress a user's new address because of mail sent to their old one" do
      Fabricate(:email_log, user: user, to_address: "member@example.com", message_id: "m-1")
      user.primary_email.update!(email: "new-member@example.com")

      event =
        receive_plunk("complaint", complaint(email: "member@example.com", event: { messageId: "m-1" }))

      expect(event.status).to eq("unmatched")
      expect_untouched(user)
    end

    it "records a conflict and applies nothing when the message belongs to another account" do
      Fabricate(:email_log, user: bystander, to_address: user.email, message_id: "shared-message")

      event = receive_plunk("complaint", complaint(event: { messageId: "shared-message" }))

      expect(event).to have_attributes(
        status: "conflict",
        outcome: "message_user_conflict",
        correlation: "message_user_conflict",
        preference_state: "skipped",
        score_state: "skipped",
      )
      expect_untouched(user)
      expect_untouched(bystander)
    end

    it "records a conflict and applies nothing for an ambiguous recipient" do
      DiscoursePlunk::RecipientResolver.stubs(:resolve).returns(
        DiscoursePlunk::RecipientResolver::Result.new(
          status: :ambiguous,
          user: nil,
          match_method: nil,
        ),
      )

      event = receive_plunk("complaint", complaint)

      expect(event).to have_attributes(status: "conflict", outcome: "ambiguous_recipient")
      expect(event.next_attempt_at).to be_nil
      expect_untouched(user)
    end

    it "revalidates ownership before delayed work: an address that moved is a conflict" do
      Email::Receiver.stubs(:update_bounce_score).raises(ActiveRecord::StatementInvalid, "down")
      event = receive_plunk("complaint", complaint)
      expect(event.status).to eq("failed")
      expect(event.preference_state).to eq("done")
      Email::Receiver.unstub(:update_bounce_score)

      # The address changes hands before the retry runs.
      user.primary_email.update!(email: "member-new@example.com")
      bystander.primary_email.update!(email: "member@example.com")

      freeze_time(2.minutes.from_now) do
        event = described_class.process(event, trigger: :retry)
      end

      expect(event).to have_attributes(status: "conflict", outcome: "recipient_owner_changed")
      expect(bounce_score(user)).to eq(0)
      expect(bounce_score(bystander)).to eq(0)
      expect_untouched(bystander)
    end

    it "does not act on bot accounts" do
      bot = Fabricate(:bot, email: "helper-bot@example.com")
      event = receive_plunk("complaint", complaint(email: "helper-bot@example.com"))

      expect(event).to have_attributes(status: "unmatched", outcome: "non_human_account")
      expect(bot.user_stat.reload.bounce_score).to eq(0)
    end
  end

  describe "message correlation" do
    it "marks an exactly matching EmailLog bounced for a bounce (angle brackets ignored)" do
      log =
        Fabricate(
          :email_log,
          user: user,
          to_address: user.email,
          message_id: "test-provider-message-id-bounce",
        )
      payload = bounce("permanent", event: { messageId: "<test-provider-message-id-bounce>" })

      event = receive_plunk("bounce", payload)

      expect(event).to have_attributes(
        correlation: "message_matched",
        email_log_id: log.id,
        correlation_state: "done",
      )
      expect(log.reload.bounced).to eq(true)
    end

    it "records the match for a complaint without marking the log bounced" do
      log =
        Fabricate(:email_log, user: user, to_address: user.email, message_id: "test-provider-message-id")

      event = receive_plunk("complaint", complaint)

      expect(event.correlation).to eq("message_matched")
      expect(event.email_log_id).to eq(log.id)
      expect(event.correlation_state).to eq("not_applicable")
      expect(log.reload.bounced).to eq(false)
    end

    it "applies account-level feedback when no message matches exactly" do
      Fabricate(:email_log, user: user, to_address: user.email, message_id: "some-other-id")
      Fabricate(
        :email_log,
        user: user,
        to_address: "someone@example.com",
        message_id: "test-provider-message-id-bounce",
      )
      # A provider id buried in the SMTP response is not a match.
      Fabricate(
        :email_log,
        user: user,
        to_address: user.email,
        message_id: "discourse-generated@forum",
        smtp_transaction_response: "250 Ok test-provider-message-id-bounce",
      )

      event = receive_plunk("bounce", bounce("permanent"))

      expect(event).to have_attributes(
        correlation: "user_matched_message_unmatched",
        email_log_id: nil,
        correlation_state: "not_applicable",
      )
      expect(EmailLog.where(bounced: true)).to be_empty
      expect_all_optional_email_off
      expect(bounce_score).to eq(SiteSetting.hard_bounce_score)
    end

    it "commits account effects and retries only the bookkeeping when the lookup fails" do
      log =
        Fabricate(
          :email_log,
          user: user,
          to_address: user.email,
          message_id: "test-provider-message-id-bounce",
        )
      DiscoursePlunk::MessageCorrelator
        .any_instance
        .stubs(:correlate)
        .returns(DiscoursePlunk::MessageCorrelator::Result.new(label: "lookup_failed", email_log_id: nil))

      event = receive_plunk("bounce", bounce("permanent"))

      expect(event).to have_attributes(
        status: "failed",
        preference_state: "done",
        score_state: "done",
      )
      expect(event.next_attempt_at).to be_present
      expect_all_optional_email_off
      expect(bounce_score).to eq(SiteSetting.hard_bounce_score)

      DiscoursePlunk::MessageCorrelator.any_instance.unstub(:correlate)
      freeze_time(2.minutes.from_now) { event = described_class.process(event, trigger: :retry) }

      expect(event).to have_attributes(status: "processed", correlation_state: "done")
      expect(log.reload.bounced).to eq(true)
      expect(bounce_score).to eq(SiteSetting.hard_bounce_score)
      expect(UserHistory.where(custom_type: "plunk_feedback_email_opt_out").count).to eq(1)
    end
  end

  describe "idempotency" do
    it "processes an identical callback once" do
      payload = complaint
      receive_plunk("complaint", payload)
      result = receive_plunk("complaint", payload)

      expect(result.status).to eq(:duplicate)
      expect(DiscoursePlunk::FeedbackEvent.count).to eq(1)
      expect(bounce_score).to eq(SiteSetting.hard_bounce_score)
      expect(UserHistory.where(custom_type: "plunk_feedback_email_opt_out").count).to eq(1)
    end

    it "treats the same message event from a different execution as the same feedback" do
      first = receive_plunk("complaint", complaint)
      second = receive_plunk("complaint", complaint)

      expect(second).to have_attributes(
        status: "processed",
        outcome: "duplicate_feedback",
        preference_state: "skipped",
        score_state: "skipped",
        score_effect: "duplicate_feedback",
        duplicate_of_event_id: first.id,
      )
      expect(bounce_score).to eq(SiteSetting.hard_bounce_score)
    end

    it "handles unsubscribe then complaint: both receipts kept, score added once" do
      receive_plunk("unsubscribe", unsubscribe(event: { reason: "complaint" }))
      complaint_event = receive_plunk("complaint", complaint)

      expect(DiscoursePlunk::FeedbackEvent.count).to eq(2)
      expect(complaint_event.outcome).to eq("already_unsubscribed")
      expect(complaint_event.score_state).to eq("done")
      expect(bounce_score).to eq(SiteSetting.hard_bounce_score)
      expect_all_optional_email_off
    end

    it "handles complaint then unsubscribe: both receipts kept, score added once" do
      receive_plunk("complaint", complaint)
      unsubscribe_event = receive_plunk("unsubscribe", unsubscribe(event: { reason: "complaint" }))

      expect(DiscoursePlunk::FeedbackEvent.count).to eq(2)
      expect(unsubscribe_event.score_state).to eq("not_applicable")
      expect(bounce_score).to eq(SiteSetting.hard_bounce_score)
      expect_all_optional_email_off
    end

    it "scores two distinct messages twice" do
      receive_plunk("complaint", complaint(event: { emailId: "email-1", messageId: "message-1" }))
      receive_plunk("complaint", complaint(event: { emailId: "email-2", messageId: "message-2" }))

      expect(bounce_score).to eq(2 * SiteSetting.hard_bounce_score)
    end

    it "does not discard a soft-to-hard transition for the same message" do
      soft = receive_plunk("bounce", bounce("transient"))
      hard = receive_plunk("bounce", bounce("permanent"))

      expect(soft.feedback_digest).not_to eq(hard.feedback_digest)
      expect(hard.score_effect).to eq("hard_bounce_score")
      expect(bounce_score).to eq(SiteSetting.soft_bounce_score + SiteSetting.hard_bounce_score)
    end

    it "scores an identical soft bounce from a second execution only once" do
      receive_plunk("bounce", bounce("transient"))
      receive_plunk("bounce", bounce("transient"))

      expect(bounce_score).to eq(SiteSetting.soft_bounce_score)
    end

    it "treats feedback without any stable identifier as distinct each time" do
      payload = -> do
        complaint.tap do |p|
          p["event"].delete("emailId")
          p["event"].delete("messageId")
        end
      end
      receive_plunk("complaint", payload.call)
      receive_plunk("complaint", payload.call)

      expect(bounce_score).to eq(2 * SiteSetting.hard_bounce_score)
    end

    it "never re-applies a completed effect after the user explicitly opts back in" do
      payload = complaint
      event = receive_plunk("complaint", payload)
      opt_in!(user)

      receive_plunk("complaint", payload) # replay of the same delivery
      receive_plunk("complaint", complaint) # same complaint, another execution
      described_class.process(event, trigger: :admin)
      described_class.process(event, trigger: :recovery)

      expect(user.user_option.reload.email_level).to eq(UserOption.email_level_types[:always])
      expect(user.user_option.chat_email_frequency).to eq("when_away")
      expect(bounce_score).to eq(SiteSetting.hard_bounce_score)
    end

    it "does apply a genuinely new unsubscribe after an opt-in" do
      receive_plunk("unsubscribe", unsubscribe)
      opt_in!(user)

      receive_plunk("unsubscribe", unsubscribe)

      expect_all_optional_email_off
    end
  end

  describe "failures and retries" do
    it "keeps the preference change when scoring fails, and retries only the score" do
      Email::Receiver.stubs(:update_bounce_score).raises(ActiveRecord::StatementInvalid, "db hiccup")

      event = receive_plunk("complaint", complaint)

      expect(event).to have_attributes(
        status: "failed",
        outcome: "retry_scheduled",
        preference_state: "done",
        score_state: "failed",
        attempts: 1,
      )
      expect(event.last_error).to include("score: ActiveRecord::StatementInvalid")
      expect(event.last_error).not_to include(user.email)
      expect_all_optional_email_off
      expect(bounce_score).to eq(0)
      expect_job_enqueued(job: :discourse_plunk_process_event, args: { event_id: event.id })

      Email::Receiver.unstub(:update_bounce_score)
      opt_in!(user) # the user changes their mind before the retry runs

      freeze_time(2.minutes.from_now) do
        Jobs::DiscoursePlunkProcessEvent.new.execute(event_id: event.id)
      end

      event.reload
      expect(event).to have_attributes(status: "processed", score_state: "done", attempts: 2)
      expect(bounce_score).to eq(SiteSetting.hard_bounce_score)
      # The preference phase was already complete; the retry did not redo it.
      expect(user.user_option.reload.email_level).to eq(UserOption.email_level_types[:always])
      expect(UserHistory.where(custom_type: "plunk_feedback_email_opt_out").count).to eq(1)
    end

    it "rolls the score back with its marker, then applies it exactly once on retry" do
      SiteSetting.bounce_score_threshold = SiteSetting.hard_bounce_score
      SystemMessage.stubs(:create_from_system_user).raises(ActiveRecord::StatementInvalid, "pm failed")

      event = receive_plunk("complaint", complaint)

      expect(event.score_state).to eq("failed")
      expect(bounce_score).to eq(0)
      expect(UserHistory.where(action: UserHistory.actions[:revoke_email]).count).to eq(0)

      SystemMessage.unstub(:create_from_system_user)
      freeze_time(2.minutes.from_now) { described_class.process(event, trigger: :retry) }

      expect(event.reload.score_state).to eq("done")
      expect(bounce_score).to eq(SiteSetting.hard_bounce_score)
      expect(UserHistory.where(action: UserHistory.actions[:revoke_email]).count).to eq(1)
    end

    it "gives up after the maximum number of attempts and stays visible" do
      Email::Receiver.stubs(:update_bounce_score).raises(ActiveRecord::StatementInvalid, "down")
      event = receive_plunk("complaint", complaint)

      (DiscoursePlunk::FeedbackEvent::MAX_ATTEMPTS - 1).times do |i|
        freeze_time((i + 1).days.from_now) { described_class.process(event, trigger: :retry) }
      end

      event.reload
      expect(event).to have_attributes(
        status: "failed",
        outcome: "retries_exhausted",
        next_attempt_at: nil,
        attempts: DiscoursePlunk::FeedbackEvent::MAX_ATTEMPTS,
      )
      expect(DiscoursePlunk::Recovery.due).to be_empty
    end

    it "does not run a retry before it is due" do
      Email::Receiver.stubs(:update_bounce_score).raises(ActiveRecord::StatementInvalid, "down")
      event = receive_plunk("complaint", complaint)

      described_class.process(event, trigger: :retry)
      expect(event.reload.attempts).to eq(1)
    end
  end

  describe "the native bounce threshold" do
    before do
      SiteSetting.bounce_score_threshold = 2 * SiteSetting.hard_bounce_score
      Jobs.run_immediately!
    end

    it "revokes email once, sends an on-site message, and emails nothing to the recipient" do
      receive_plunk("complaint", complaint(event: { emailId: "a" }))
      receive_plunk("complaint", complaint(event: { emailId: "b" }))
      receive_plunk("complaint", complaint(event: { emailId: "b" })) # same complaint again

      expect(bounce_score).to eq(SiteSetting.bounce_score_threshold)
      expect(UserHistory.where(action: UserHistory.actions[:revoke_email], target_user_id: user.id).count).to eq(1)
      revoked =
        Topic
          .private_messages_for_user(user)
          .where(title: I18n.t("system_messages.email_revoked.subject_template"))
      expect(revoked.count).to eq(1)
      expect(ActionMailer::Base.deliveries.map(&:to).flatten).not_to include(user.email)
    end
  end

  describe "restart recovery" do
    it "finishes a receipt that was committed but never processed" do
      parsed = DiscoursePlunk::Payload.parse("email.complaint", complaint)
      event = DiscoursePlunk::Receiver.accept(parsed).event
      expect(event.status).to eq("received")
      expect(email_off?(user)).to eq(false)

      # Too young: it may still be inside its own webhook request.
      Jobs::DiscoursePlunkRecoverEvents.new.execute({})
      expect(event.reload.status).to eq("received")

      freeze_time(3.minutes.from_now) { Jobs::DiscoursePlunkRecoverEvents.new.execute({}) }

      expect(event.reload.status).to eq("processed")
      expect_all_optional_email_off
      expect(bounce_score).to eq(SiteSetting.hard_bounce_score)
    end

    it "does nothing while the plugin is disabled" do
      parsed = DiscoursePlunk::Payload.parse("email.complaint", complaint)
      event = DiscoursePlunk::Receiver.accept(parsed).event
      SiteSetting.plunk_feedback_enabled = false

      freeze_time(3.minutes.from_now) { Jobs::DiscoursePlunkRecoverEvents.new.execute({}) }

      expect(event.reload.status).to eq("received")
      expect(email_off?(user)).to eq(false)
    end
  end
end
