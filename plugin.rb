# frozen_string_literal: true

# name: discourse-plunk-email
# about: Receives Plunk unsubscribe, complaint and bounce feedback over authenticated webhooks and applies Discourse's native email preferences and bounce scoring.
# version: 1.0.0
# authors: multidimension.al
# url: https://github.com/multidimension-al/discourse-plunk-email
# required_version: 2026.9.0-latest

enabled_site_setting :plunk_feedback_enabled

register_asset "stylesheets/plunk-feedback-admin.scss"

module ::DiscoursePlunk
  PLUGIN_NAME = "discourse-plunk-email"

  # Plunk workflow trigger => the route that receives it. The route, not the
  # payload, names the event: Plunk's default webhook body has no event-name
  # field, so each of the three workflows must point at its own URL.
  ROUTES = {
    "unsubscribe" => "contact.unsubscribed",
    "complaint" => "email.complaint",
    "bounce" => "email.bounce",
  }.freeze

  WEBHOOK_PATH = "/discourse-plunk/webhooks"

  def self.webhook_url(route)
    "#{Discourse.base_url}#{WEBHOOK_PATH}/#{route}"
  end
end

# Loaded before settings are validated: the secret settings name this class.
require_relative "lib/discourse_plunk/webhook_secret_validator"

# Rails logs every action's parameters at INFO.
#
# - The webhook body carries the recipient address and Plunk's message
#   metadata. The first filter is a deep (dotted-path) filter: it matches only
#   keys nested under a top-level contact/event/workflow/execution object —
#   the shape of Plunk's payload — and leaves every other parameter alone.
# - Saving the secret through the admin UI sends it as a parameter named after
#   the setting (`plunk_feedback_webhook_secret=…`, or
#   `settings[plunk_feedback_webhook_secret][value]=…`). The second filter
#   matches exactly those two setting names.
#
# `concat` mutates the array Rails already holds, so the filters apply no
# matter when the request environment was first built.
Rails.application.config.filter_parameters.concat(
  [
    /\A(?:contact|event|workflow|execution)\..+\z/,
    /\Aplunk_feedback_webhook(?:_previous)?_secret\z/,
  ],
)

add_admin_route "discourse_plunk.admin.title", "discourse-plunk-email", use_new_show_route: true

after_initialize do
  require_relative "app/models/discourse_plunk/feedback_event"
  require_relative "app/models/discourse_plunk/tombstone"
  require_relative "lib/discourse_plunk/payload"
  require_relative "lib/discourse_plunk/receiver"
  require_relative "lib/discourse_plunk/recipient_resolver"
  require_relative "lib/discourse_plunk/message_correlator"
  require_relative "lib/discourse_plunk/optional_email_preferences"
  require_relative "lib/discourse_plunk/processor"
  require_relative "lib/discourse_plunk/recovery"
  require_relative "lib/discourse_plunk/retention"
  require_relative "lib/discourse_plunk/queued_email_guard"
  require_relative "lib/discourse_plunk/backfill"
  require_relative "app/serializers/discourse_plunk/feedback_event_serializer"
  require_relative "app/controllers/discourse_plunk/webhooks_controller"
  require_relative "app/controllers/discourse_plunk/admin_feedback_controller"
  require_relative "app/jobs/regular/discourse_plunk_process_event"
  require_relative "app/jobs/scheduled/discourse_plunk_recover_events"
  require_relative "app/jobs/scheduled/discourse_plunk_purge_events"

  # A notification email is queued with a delay (email_time_window_mins for
  # replies and mentions, personal_email_time_window_seconds for PMs) and
  # Jobs::UserEmail does not look at email_level / email_messages_level again
  # when it finally runs. This narrow prepend re-reads the native preference
  # for users this plugin has opted out, so mail queued just before a complaint
  # is skipped rather than sent. Every other job type, and every critical
  # email, goes straight to core. Same mechanism bundled Chat and Policy use
  # on UserNotifications.
  reloadable_patch { ::Jobs::UserEmail.prepend(DiscoursePlunk::QueuedEmailGuard::JobExtension) }

  Discourse::Application.routes.append do
    # Machine-to-machine routes. The controller is not an ApplicationController,
    # so login_required, CSRF and the XHR check never apply to it; the bearer
    # secret is the only credential it accepts.
    scope DiscoursePlunk::WEBHOOK_PATH, defaults: { format: :json } do
      DiscoursePlunk::ROUTES.each_key do |route|
        post route => "discourse_plunk/webhooks##{route}"
        match route => "discourse_plunk/webhooks#method_not_allowed",
              :via => %i[get put patch delete options]
      end
    end

    # Full-page load of the admin page (core only routes
    # /admin/plugins/:plugin_id and .../settings itself).
    get "/admin/plugins/discourse-plunk-email/plunk-feedback" => "admin/plugins#index",
        :constraints => AdminConstraint.new

    scope "/admin/plugins/discourse-plunk-email/feedback",
          constraints: AdminConstraint.new,
          defaults: {
            format: :json,
          } do
      get "status" => "discourse_plunk/admin_feedback#status"
      get "events" => "discourse_plunk/admin_feedback#index"
      get "events/:id" => "discourse_plunk/admin_feedback#show", :constraints => { id: /\d+/ }
      post "events/:id/reprocess" => "discourse_plunk/admin_feedback#reprocess",
           :constraints => {
             id: /\d+/,
           }
    end
  end
end
