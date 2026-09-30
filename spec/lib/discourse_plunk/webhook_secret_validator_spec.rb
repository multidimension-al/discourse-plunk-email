# frozen_string_literal: true

RSpec.describe DiscoursePlunk::WebhookSecretValidator do
  subject(:validator) { described_class.new }

  it "allows blank, which means not configured (every webhook is refused)" do
    expect(validator.valid_value?("")).to eq(true)
  end

  it "accepts every random hex secret, not just most of them" do
    200.times { expect(validator.valid_value?(SecureRandom.hex(32))).to eq(true) }
  end

  it "accepts the documented generators' output" do
    expect(validator.valid_value?(SecureRandom.base64(48))).to eq(true) # openssl rand -base64 48
    expect(validator.valid_value?(SecureRandom.hex(32))).to eq(true) # openssl rand -hex 32
    expect(validator.valid_value?(SecureRandom.urlsafe_base64(32))).to eq(true)
  end

  it "rejects short secrets" do
    expect(validator.valid_value?(SecureRandom.hex(16))).to eq(false)
    expect(validator.error_message).to include("43")
  end

  it "rejects whitespace and other characters that do not belong in a header token" do
    expect(validator.valid_value?("#{SecureRandom.hex(24)} #{SecureRandom.hex(24)}")).to eq(false)
    expect(validator.valid_value?("#{SecureRandom.hex(24)}\"")).to eq(false)
  end

  it "rejects obviously non-random values" do
    expect(validator.valid_value?("a" * 64)).to eq(false)
    expect(validator.valid_value?("abcabcabc" * 8)).to eq(false)
  end

  it "rejects an existing admin API key" do
    key = ApiKey.create!(description: "test")
    expect(validator.valid_value?(key.key)).to eq(false)
    expect(validator.error_message).to include("API key")
  end

  it "rejects an existing user API key" do
    key = Fabricate(:readonly_user_api_key)
    expect(validator.valid_value?(key.key)).to eq(false)
  end

  it "rejects the SMTP password" do
    password = SecureRandom.base64(48)
    GlobalSetting.stubs(:smtp_password).returns(password)
    expect(validator.valid_value?(password)).to eq(false)
  end

  it "is enforced when the site setting is saved" do
    expect { SiteSetting.plunk_feedback_webhook_secret = "too-short" }.to raise_error(
      Discourse::InvalidParameters,
    )
    expect(SiteSetting.plunk_feedback_webhook_secret).to eq("")
  end

  it "keeps the secret settings server-side only and masked" do
    expect(SiteSetting.client_settings_json).not_to include("plunk_feedback_webhook")
    expect(SiteSetting.secret_settings).to include(
      :plunk_feedback_webhook_secret,
      :plunk_feedback_webhook_previous_secret,
    )
  end

  it "logs secret changes to staff history only as [FILTERED]" do
    admin = Fabricate(:admin)
    secret = SecureRandom.base64(48)
    SiteSetting.set_and_log(:plunk_feedback_webhook_secret, secret, admin)

    history = UserHistory.where(subject: "plunk_feedback_webhook_secret").last
    expect(history.new_value).to eq("[FILTERED]")
    expect(
      UserHistory.where("new_value LIKE ? OR details LIKE ?", "%#{secret}%", "%#{secret}%"),
    ).to be_empty
  end
end
