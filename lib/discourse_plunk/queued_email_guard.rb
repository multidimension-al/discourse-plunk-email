# frozen_string_literal: true

module DiscoursePlunk
  # Re-checks the native preference when a queued notification email runs.
  #
  # NotificationEmailer checks email_level / email_messages_level when it
  # *enqueues* Jobs::UserEmail, with a delay of email_time_window_mins (or
  # personal_email_time_window_seconds for PMs). Jobs::UserEmail does not
  # look at those preferences again, so without this a reply notification
  # queued a few minutes before a complaint would still be sent afterwards.
  # Digests, mailing-list mode and Chat summaries already re-read their
  # preferences at send time and are left to core.
  #
  # Scope is deliberately narrow: only the job types below, never a critical
  # email type, only while the plugin is enabled, and only for users this
  # plugin has applied an opt-out to. The decision is always the user's
  # *current* native preference — if they have turned email back on, mail
  # flows. There is no separate suppression list.
  module QueuedEmailGuard
    PREFERENCE_BY_TYPE = {
      # NotificationEmailer::EmailUser#enqueue (email_level)
      "user_mentioned" => :email_level,
      "group_mentioned" => :email_level,
      "user_posted" => :email_level,
      "user_quoted" => :email_level,
      "user_replied" => :email_level,
      "user_linked" => :email_level,
      "user_watching_first_post" => :email_level,
      "post_approved" => :email_level,
      "user_invited_to_private_message" => :email_level,
      "user_invited_to_topic" => :email_level,
      # NotificationEmailer::EmailUser#enqueue_private (email_messages_level)
      "user_private_message" => :email_messages_level,
      # discourse-policy reminders (policy_email_frequency)
      "policy_email" => :policy_email_frequency,
    }.freeze

    def self.skip_reason(user, type)
      return if !SiteSetting.plunk_feedback_enabled
      return if user.nil? || EmailLog::CRITICAL_EMAIL_TYPES.include?(type)

      preference = PREFERENCE_BY_TYPE[type]
      return if preference.nil?

      option = UserOption.find_by(user_id: user.id)
      return if option.nil? || !disabled?(option, preference)
      return if !FeedbackEvent.where(user_id: user.id, preference_state: "done").exists?

      preference
    end

    def self.disabled?(option, preference)
      case preference
      when :email_level
        option.email_level == UserOption.email_level_types[:never]
      when :email_messages_level
        option.email_messages_level == UserOption.email_level_types[:never]
      when :policy_email_frequency
        option.has_attribute?(:policy_email_frequency) &&
          option.read_attribute(:policy_email_frequency).to_s == "never"
      else
        false
      end
    end

    module JobExtension
      def message_for_email(user, post, type, notification, args = nil)
        preference = DiscoursePlunk::QueuedEmailGuard.skip_reason(user, type.to_s)
        return super if preference.nil?

        to_address = args&.[](:to_address).presence || user.email
        log =
          SkippedEmailLog.create!(
            email_type: type.to_s,
            to_address: to_address,
            user_id: user.id,
            post_id: post&.id,
            reason_type: SkippedEmailLog.reason_types[:custom],
            custom_reason: I18n.t("discourse_plunk.skipped_email_reason", preference: preference),
          )
        [nil, log]
      end
    end
  end
end
