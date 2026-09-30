# frozen_string_literal: true

module PlunkSpecHelpers
  # A fresh, well-formed secret per test run; never a checked-in value.
  def plunk_secret
    @plunk_secret ||= SecureRandom.base64(48)
  end

  def enable_plunk!(secret: plunk_secret)
    SiteSetting.plunk_feedback_webhook_secret = secret
    SiteSetting.plunk_feedback_enabled = true
  end

  def plunk_fixture(name)
    JSON.parse(File.read(File.expand_path("../fixtures/plunk/#{name}.json", __dir__)))
  end

  # A fixture addressed to `email`, with its own execution id unless given,
  # and optional overrides merged into the event object.
  def plunk_payload(name, email:, execution_id: nil, workflow_id: nil, event: {})
    payload = plunk_fixture(name)
    payload["contact"]["email"] = email
    payload["execution"]["id"] = execution_id || "exec_test_#{SecureRandom.hex(6)}"
    payload["workflow"]["id"] = workflow_id if workflow_id
    payload["event"] = (payload["event"] || {}).merge(event.stringify_keys)
    payload
  end

  def plunk_headers(secret: plunk_secret)
    { "Authorization" => "Bearer #{secret}", "CONTENT_TYPE" => "application/json" }
  end

  def post_plunk(route, payload, headers: plunk_headers)
    body = payload.is_a?(String) ? payload : payload.to_json
    post "/discourse-plunk/webhooks/#{route}", params: body, headers: headers
  end

  # The same path a webhook request takes, without HTTP.
  def receive_plunk(route, payload, source: "webhook")
    parsed = DiscoursePlunk::Payload.parse(DiscoursePlunk::ROUTES.fetch(route), payload)
    result = DiscoursePlunk::Receiver.accept(parsed, source: source)
    return result if result.status != :created

    DiscoursePlunk::Processor.process(result.event, trigger: :webhook)
  end

  def email_off?(user)
    DiscoursePlunk::OptionalEmailPreferences.all_disabled?(user.user_option.reload)
  end

  def opt_in!(user)
    user.user_option.update!(
      email_level: UserOption.email_level_types[:always],
      email_messages_level: UserOption.email_level_types[:always],
      email_digests: true,
      digest_after_minutes: 10_080,
      mailing_list_mode: false,
    )
    user.user_option.update!(chat_email_frequency: "when_away") if user.user_option.has_attribute?(:chat_email_frequency)
  end
end

RSpec.configure { |config| config.include PlunkSpecHelpers }
