# frozen_string_literal: true

require_relative "../support/plunk_helpers"

# Drives Discourse's real email-producing code paths before and after Plunk
# feedback is processed. Every "after" case has a matching control showing
# the same path does send mail to the same user beforehand.
RSpec.describe "Plunk feedback and Discourse's email paths" do
  fab!(:user) do
    Fabricate(
      :user,
      email: "reader@example.com",
      trust_level: TrustLevel[1],
      last_seen_at: 8.days.ago,
    )
  end
  fab!(:author) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:topic) { Fabricate(:topic, user: author) }
  fab!(:first_post) { Fabricate(:post, topic: topic, user: author) }

  before do
    enable_plunk!
    opt_in!(user)
    Group.refresh_automatic_groups!
    NotificationEmailer.enable
    ActionMailer::Base.deliveries.clear
  end

  def complaint
    plunk_payload("synthetic-email-complaint", email: user.email)
  end

  def deliveries_to(u)
    ActionMailer::Base.deliveries.select { |mail| Array(mail.to).include?(u.email) }
  end

  def reply(raw = "A reply that watchers of this topic are emailed about. #{SecureRandom.hex(4)}")
    PostCreator.create!(author, topic_id: topic.id, raw: raw)
  end

  def private_message
    PostCreator.create!(
      author,
      title: "A private message for the reader #{SecureRandom.hex(4)}",
      raw: "The body of a private message long enough to be valid. #{SecureRandom.hex(4)}",
      archetype: Archetype.private_message,
      target_usernames: user.username,
    )
  end

  it "only ever uses the test mail delivery method" do
    expect(ActionMailer::Base.delivery_method).to eq(:test)
  end

  it "sends nothing to the recipient while processing feedback (no confirmation email)" do
    Jobs.run_immediately!
    receive_plunk("complaint", complaint)

    expect(ActionMailer::Base.deliveries).to be_empty
  end

  it "never builds a synthetic bounce message or runs the inbound-mail parser" do
    Email::Receiver.expects(:new).never
    expect { receive_plunk("complaint", complaint) }.not_to change { IncomingEmail.count }
  end

  describe "topic notification email" do
    before do
      Jobs.run_immediately!
      TopicUser.change(
        user.id,
        topic.id,
        notification_level: TopicUser.notification_levels[:watching],
      )
    end

    it "is sent before feedback and not after; in-app notifications and the watch continue" do
      reply
      expect(deliveries_to(user).size).to eq(1)

      ActionMailer::Base.deliveries.clear
      last_notification_id = Notification.where(user: user).maximum(:id)
      receive_plunk("complaint", complaint)
      reply

      expect(deliveries_to(user)).to be_empty
      # The in-app notification for the new reply is still created.
      expect(
        Notification.where(user: user, topic: topic).where("id > ?", last_notification_id),
      ).to exist
      expect(TopicUser.get(topic, user).notification_level).to eq(
        TopicUser.notification_levels[:watching],
      )
    end
  end

  describe "private message notification email" do
    before { Jobs.run_immediately! }

    it "is sent before feedback and not after; the PM itself is still delivered on-site" do
      private_message
      expect(deliveries_to(user).size).to eq(1)

      ActionMailer::Base.deliveries.clear
      receive_plunk("complaint", complaint)
      pm = private_message

      expect(deliveries_to(user)).to be_empty
      expect(pm.topic.allowed_users).to include(user)
      expect(
        Notification.where(
          user: user,
          topic: pm.topic,
          notification_type: Notification.types[:private_message],
        ),
      ).to exist
    end
  end

  describe "digest email" do
    it "targets the user before feedback and not after; a queued digest sends nothing" do
      expect(Jobs::EnqueueDigestEmails.new.target_user_ids).to include(user.id)

      receive_plunk("complaint", complaint)

      expect(Jobs::EnqueueDigestEmails.new.target_user_ids).not_to include(user.id)
      Jobs::UserEmail.new.execute(type: :digest, user_id: user.id)
      expect(deliveries_to(user)).to be_empty
    end
  end

  describe "mailing-list mode" do
    before do
      SiteSetting.disable_mailing_list_mode = false
      user.user_option.reload.update!(mailing_list_mode: true, mailing_list_mode_frequency: 1)
    end

    it "mails every post before feedback and nothing after" do
      post =
        Fabricate(:post, topic: topic, user: author, raw: "Mailing list post one, long enough.")
      Jobs::NotifyMailingListSubscribers.new.execute(post_id: post.id)
      expect(deliveries_to(user).size).to eq(1)

      ActionMailer::Base.deliveries.clear
      receive_plunk("complaint", complaint)
      expect(user.user_option.reload.mailing_list_mode).to eq(false)

      post =
        Fabricate(:post, topic: topic, user: author, raw: "Mailing list post two, long enough.")
      Jobs::NotifyMailingListSubscribers.new.execute(post_id: post.id)
      expect(deliveries_to(user)).to be_empty
    end
  end

  describe "Chat summary email" do
    fab!(:dm) { Fabricate(:direct_message_channel, users: [user, author]) }

    before do
      SiteSetting.chat_enabled = true
      SiteSetting.chat_allowed_groups = Group::AUTO_GROUPS[:everyone]
      user.update!(last_seen_at: 1.hour.ago)
      Jobs.run_immediately!
    end

    it "is sent before feedback and not after" do
      Fabricate(:chat_message, user: author, chat_channel: dm, message: "Unread direct message one")
      Chat::Mailer.send_unread_mentions_summary
      expect(deliveries_to(user).size).to eq(1)

      ActionMailer::Base.deliveries.clear
      receive_plunk("complaint", complaint)

      Fabricate(:chat_message, user: author, chat_channel: dm, message: "Unread direct message two")
      Chat::Mailer.send_unread_mentions_summary
      expect(deliveries_to(user)).to be_empty
    end
  end

  describe "email queued before the feedback arrived" do
    # Sidekiq is in fake mode here: jobs are queued, not run, as in production
    # during email_time_window_mins.
    def queue_reply_notification
      TopicUser.change(
        user.id,
        topic.id,
        notification_level: TopicUser.notification_levels[:watching],
      )
      post = reply
      Jobs::PostAlert.new.execute(post_id: post.id, new_record: true)
      queued_email_for(user)
    end

    def queue_private_message_notification
      pm = private_message
      Jobs::PostAlert.new.execute(post_id: pm.id, new_record: true)
      queued_email_for(user)
    end

    def queued_email_for(u)
      jobs = Jobs::UserEmail.jobs.select { |job| job["args"].first["user_id"] == u.id }
      expect(jobs.size).to eq(1)
      jobs.first["args"].first
    end

    def run(args)
      Jobs::UserEmail.new.perform(args)
    end

    it "sends a queued reply notification when there is no feedback (control)" do
      args = queue_reply_notification
      run(args)
      expect(deliveries_to(user).size).to eq(1)
    end

    it "skips a reply notification queued before a complaint, with a visible reason" do
      args = queue_reply_notification
      receive_plunk("complaint", complaint)

      run(args)

      expect(deliveries_to(user)).to be_empty
      skipped = SkippedEmailLog.where(user_id: user.id).last
      expect(skipped.reason_type).to eq(SkippedEmailLog.reason_types[:custom])
      expect(skipped.custom_reason).to include("email_level")
    end

    it "skips a PM notification queued before a complaint" do
      args = queue_private_message_notification
      expect(args["type"]).to eq("user_private_message")
      receive_plunk("complaint", complaint)

      run(args)

      expect(deliveries_to(user)).to be_empty
      expect(SkippedEmailLog.where(user_id: user.id).last.custom_reason).to include(
        "email_messages_level",
      )
    end

    it "sends the queued email if the user has explicitly opted back in by the time it runs" do
      args = queue_reply_notification
      receive_plunk("complaint", complaint)
      opt_in!(user)

      run(args)

      expect(deliveries_to(user).size).to eq(1)
    end

    it "leaves core behaviour alone for users the plugin never touched" do
      args = queue_reply_notification
      user.user_option.reload.update!(email_level: UserOption.email_level_types[:never])

      run(args)

      # Core does not re-check email_level for an already-queued job; this
      # plugin only adds that re-check for accounts it has opted out.
      expect(deliveries_to(user).size).to eq(1)
    end

    it "does nothing while the plugin is disabled" do
      args = queue_reply_notification
      receive_plunk("complaint", complaint)
      SiteSetting.plunk_feedback_enabled = false

      run(args)

      expect(deliveries_to(user).size).to eq(1)
    end
  end

  describe "account recovery and security email" do
    before do
      # Put the user over the native bounce threshold as well.
      SiteSetting.bounce_score_threshold = SiteSetting.hard_bounce_score
      receive_plunk("complaint", complaint)
      expect(user.user_stat.reload.bounce_score).to be >= SiteSetting.bounce_score_threshold
    end

    it "still sends a password reset" do
      token = Fabricate(:email_token, user: user, scope: EmailToken.scopes[:password_reset])
      Jobs::CriticalUserEmail.new.execute(
        type: :forgot_password,
        user_id: user.id,
        email_token: token.token,
      )

      expect(deliveries_to(user).size).to eq(1)
    end

    it "still sends an admin-login link through the regular job" do
      SiteSetting.enable_local_logins = true
      Jobs::UserEmail.new.execute(type: :admin_login, user_id: user.id, email_token: "abc123")

      expect(EmailLog.exists?(email_type: "admin_login", user: user)).to eq(true)
    end

    it "still sends activation email to an account that has not been activated" do
      inactive = Fabricate(:inactive_user, email: "new-signup@example.com")
      receive_plunk("complaint", plunk_payload("synthetic-email-complaint", email: inactive.email))
      token = Fabricate(:email_token, user: inactive, scope: EmailToken.scopes[:signup])

      Jobs::CriticalUserEmail.new.execute(
        type: :signup,
        user_id: inactive.id,
        email_token: token.token,
      )

      expect(deliveries_to(inactive).size).to eq(1)
      expect(DiscoursePlunk::FeedbackEvent.last.match_method).to eq("primary_email_unactivated")
    end

    it "does not block the user from logging in or using the forum" do
      user.reload
      expect(user.active).to eq(true)
      expect(user.suspended?).to eq(false)
      expect(user.silenced?).to eq(false)
      expect(Guardian.new(user).can_create_post?(topic)).to eq(true)
    end
  end
end
