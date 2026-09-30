# frozen_string_literal: true

module DiscoursePlunk
  # Validates the shared webhook secret settings.
  #
  # Blank is allowed and means "not configured": the receiver then refuses
  # every request, so clearing the setting fails closed rather than open.
  # Anything else must look like the output of the documented generator
  # (`openssl rand -base64 48` or `openssl rand -hex 32`, i.e. at least 32
  # random bytes) and must not be a credential that already exists for
  # another purpose.
  class WebhookSecretValidator
    MIN_LENGTH = 43 # 32 bytes, base64url without padding
    MAX_LENGTH = 256
    CHARSET = %r{\A[A-Za-z0-9+/=_.~-]+\z}
    MIN_DISTINCT_CHARACTERS = 16

    def initialize(opts = {})
      @opts = opts
    end

    def valid_value?(value)
      @error = nil
      return true if value.blank?

      value = value.to_s
      if value.length < MIN_LENGTH || value.length > MAX_LENGTH
        @error = :length
      elsif !value.match?(CHARSET)
        @error = :charset
      elsif value.chars.uniq.size < MIN_DISTINCT_CHARACTERS
        @error = :entropy
      elsif reused_credential?(value)
        @error = :reused
      end

      @error.nil?
    end

    def error_message
      I18n.t(
        "site_settings.errors.plunk_feedback_webhook_secret.#{@error || :length}",
        min: MIN_LENGTH,
        max: MAX_LENGTH,
      )
    end

    private

    def reused_credential?(value)
      smtp_password = GlobalSetting.smtp_password.to_s
      if smtp_password.present? &&
           ActiveSupport::SecurityUtils.secure_compare(smtp_password, value)
        return true
      end

      # Admin and user API keys are stored only as a hash (both via
      # ApiKey.hash_key), which is enough to recognise one.
      key_hash = ::ApiKey.hash_key(value)
      ::ApiKey.where(key_hash: key_hash).exists? || ::UserApiKey.where(key_hash: key_hash).exists?
    end
  end
end
