# frozen_string_literal: true

module DiscoursePlunk
  # Turns off every optional-email preference a user has, through Discourse's
  # own unsubscribe strategies, and verifies the result.
  #
  # Core: the "digest" strategy (EmailControllerHelper::DigestEmailUnsubscriber)
  # given `unsubscribe_all` runs BaseEmailUnsubscriber's unsubscribe-all —
  # email_level and email_messages_level to :never, email_digests and
  # mailing_list_mode off — and then sets digest_after_minutes to the
  # "never" digest frequency, so the visible frequency matches.
  #
  # Plugins: bundled Chat (chat_email_frequency) and Policy
  # (policy_email_frequency) keep their own frequency and register their own
  # unsubscribe strategy. When the plugin's strategy is registered it is used;
  # when the plugin is installed but switched off its strategy is not
  # registered, so the column is set to the named "never" value directly —
  # otherwise summaries would resume the moment the plugin was re-enabled.
  #
  # The strategies run against an UnsubscribeKey that is built in memory and
  # never saved: no token is created or exposed.
  #
  # Deliberately untouched: formatting options (email_in_reply_to,
  # email_previous_replies, include_tl0_in_digests), notification and push
  # settings, watch levels, bookmarks, groups, trust level and account status.
  class OptionalEmailPreferences
    class PostconditionFailed < StandardError
    end

    Extension =
      Data.define(:column, :strategy_type, :enum_method) do
        def installed?
          UserOption.column_names.include?(column) && UserOption.respond_to?(enum_method)
        end

        def never_value
          UserOption.public_send(enum_method).fetch(:never)
        end
      end

    CORE_COLUMNS = %w[
      email_level
      email_messages_level
      email_digests
      mailing_list_mode
      digest_after_minutes
    ].freeze

    EXTENSIONS = [
      Extension.new(
        column: "chat_email_frequency",
        strategy_type: "chat_summary",
        enum_method: :chat_email_frequencies,
      ),
      Extension.new(
        column: "policy_email_frequency",
        strategy_type: "policy_email",
        enum_method: :policy_email_frequencies,
      ),
    ].freeze

    def self.installed_extensions
      EXTENSIONS.select(&:installed?)
    end

    def self.never_digest_minutes
      DigestEmailSiteSetting.values.find { |v| v[:name] == "never" }.fetch(:value)
    end

    def self.columns
      CORE_COLUMNS + installed_extensions.map(&:column)
    end

    attr_reader :strategies_used

    def initialize(user)
      @user = user
      @strategies_used = []
    end

    # Must run inside the caller's transaction, with the user_option row
    # already locked. Returns { column => [before, after] } for every column
    # that changed (empty when the user had already opted out of everything).
    def disable_all!
      option = @user.user_option
      before = snapshot(option)

      apply_core
      self.class.installed_extensions.each { |extension| apply_extension(extension) }

      option.reload
      verify!(option)
      after = snapshot(option)

      self.class.columns.each_with_object({}) do |column, changes|
        changes[column] = [before[column], after[column]] if before[column] != after[column]
      end
    end

    # Every optional-email preference is off.
    def self.all_disabled?(option)
      option.unsubscribed_from_all? && option.read_attribute(:mailing_list_mode) == false &&
        option.digest_after_minutes.to_i == never_digest_minutes &&
        installed_extensions.all? { |ext| option.read_attribute(ext.column).to_s == "never" }
    end

    private

    def apply_core
      key = UnsubscribeKey.new(user: @user, unsubscribe_key_type: UnsubscribeKey::DIGEST_TYPE)
      strategy = UnsubscribeKey.get_unsubscribe_strategy_for(key)
      strategy.unsubscribe(
        unsubscribe_all: true,
        digest_after_minutes: self.class.never_digest_minutes.to_s,
      )
      @strategies_used << strategy.class.name
    end

    def apply_extension(extension)
      key = UnsubscribeKey.new(user: @user, unsubscribe_key_type: extension.strategy_type)
      strategy = UnsubscribeKey.get_unsubscribe_strategy_for(key)

      if strategy
        begin
          strategy.unsubscribe(extension.column.to_sym => "never")
          @strategies_used << strategy.class.name
          return
        rescue ActiveRecord::RecordInvalid
          # The plugin strategy saves the whole user_option with validations;
          # an unrelated invalid column (say, a stale timezone) must not keep
          # this preference on. Fall through to the direct write.
        end
      end

      @user.user_option.update_columns(extension.column => extension.never_value)
      @strategies_used << "#{extension.column}=never"
    end

    def verify!(option)
      return if self.class.all_disabled?(option)

      still_enabled =
        self.class.columns.reject do |column|
          value = option.read_attribute(column)
          case column
          when "email_level", "email_messages_level"
            value == UserOption.email_level_types[:never]
          when "email_digests", "mailing_list_mode"
            value == false
          when "digest_after_minutes"
            value.to_i == self.class.never_digest_minutes
          else
            value.to_s == "never"
          end
        end

      raise PostconditionFailed, "optional email still enabled: #{still_enabled.join(", ")}"
    end

    def snapshot(option)
      self.class.columns.index_with do |column|
        value = option.read_attribute(column)
        if %w[email_level email_messages_level].include?(column)
          UserOption.email_level_types[value]&.to_s || value
        else
          value
        end
      end
    end
  end
end
