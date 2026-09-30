# frozen_string_literal: true

require_relative "../support/plunk_helpers"

describe "Plunk feedback admin page" do
  fab!(:admin)
  fab!(:member) { Fabricate(:user, email: "member@example.com") }
  fab!(:other) { Fabricate(:user, email: "other@example.com") }

  before do
    enable_plunk!
    sign_in(admin)
  end

  # Core's first /admin/plugins request in a fresh process reads git metadata
  # for every bundled plugin (measured at ~4.7s cold, ~0.1s after), which can
  # exceed the default 4s client-settle wait on a slow runner.
  around do |example|
    original = Capybara.default_max_wait_time
    Capybara.default_max_wait_time = 10
    example.run
  ensure
    Capybara.default_max_wait_time = original
  end

  def failed_complaint
    Email::Receiver.stubs(:update_bounce_score).raises(ActiveRecord::StatementInvalid, "down")
    event =
      receive_plunk("complaint", plunk_payload("synthetic-email-complaint", email: member.email))
    Email::Receiver.unstub(:update_bounce_score)
    event
  end

  it "is reachable from the plugin's admin nav" do
    visit "/admin/plugins/discourse-plunk-email"

    expect(page).to have_css(".plunk-feedback-admin")
    expect(page).to have_current_path("/admin/plugins/discourse-plunk-email/plunk-feedback")
  end

  it "shows configuration, copyable webhook URLs and counts without revealing the secret" do
    receive_plunk(
      "unsubscribe",
      plunk_payload("synthetic-contact-unsubscribed", email: other.email),
    )

    visit "/admin/plugins/discourse-plunk-email/plunk-feedback"

    urls = find(".plunk-feedback-admin__urls")
    %w[unsubscribe complaint bounce].each do |route|
      expect(urls).to have_content("#{Discourse.base_url}/discourse-plunk/webhooks/#{route}")
    end
    expect(urls).to have_css(".copy-button", count: 3)
    expect(page).to have_content(I18n.t("js.discourse_plunk.admin.configured"))
    expect(page).not_to have_content(SiteSetting.plunk_feedback_webhook_secret)
    expect(find(".plunk-feedback-admin__counts")).to have_content(
      "1#{I18n.t("js.discourse_plunk.admin.counts.processed")}",
    )
  end

  it "searches, shows an event's detail and reprocesses it" do
    event = failed_complaint
    receive_plunk(
      "unsubscribe",
      plunk_payload("synthetic-contact-unsubscribed", email: other.email),
    )

    visit "/admin/plugins/discourse-plunk-email/plunk-feedback"
    expect(page).to have_css(".plunk-feedback-admin__event", count: 2)

    find(".plunk-feedback-admin__search input[type='search']").fill_in(with: "member@")
    find(".plunk-feedback-admin__search .btn-primary").click
    expect(page).to have_css(".plunk-feedback-admin__event", count: 1)

    find(".plunk-feedback-admin__show").click
    detail = find(".plunk-feedback-admin__detail")
    expect(detail).to have_content("email.complaint")
    expect(detail).to have_content("member@example.com")
    expect(detail).to have_content("test-plunk-email-id")
    expect(detail).to have_content("email_level: always → never").or have_content(
           "email_level: only_when_away → never",
         )
    expect(detail).to have_css(".plunk-feedback-admin__status--retrying")

    find(".plunk-feedback-admin__reprocess").click

    expect(page).to have_css(
      ".plunk-feedback-admin__detail .plunk-feedback-admin__status--processed",
    )
    expect(page).to have_no_css(".plunk-feedback-admin__reprocess")
    expect(event.reload.status).to eq("processed")
    expect(member.user_stat.reload.bounce_score).to eq(SiteSetting.hard_bounce_score)
  end
end
