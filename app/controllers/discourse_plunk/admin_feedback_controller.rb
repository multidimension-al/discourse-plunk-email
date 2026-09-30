# frozen_string_literal: true

module DiscoursePlunk
  # Administrator-only diagnostics and safe reprocessing. Inherits the admin
  # controller's login, admin check and CSRF protection. Deliberately without
  # requires_plugin: history must stay inspectable while the receiver is
  # disabled (during a rollback, say). Reprocessing checks the setting itself.
  class AdminFeedbackController < ::Admin::AdminController # rubocop:disable Discourse/Plugins/CallRequiresPlugin
    PAGE_SIZE = 50

    def status
      render json: {
               enabled: SiteSetting.plunk_feedback_enabled,
               secret_configured: SiteSetting.plunk_feedback_webhook_secret.present?,
               previous_secret_configured:
                 SiteSetting.plunk_feedback_webhook_previous_secret.present?,
               recovery_healthy: Recovery.healthy?,
               retention_days: SiteSetting.plunk_feedback_event_retention_days,
               optional_preferences: OptionalEmailPreferences.columns,
               webhooks:
                 DiscoursePlunk::ROUTES.map do |route, kind|
                   { trigger: kind, route: route, url: DiscoursePlunk.webhook_url(route) }
                 end,
               last_received_at: FeedbackEvent.maximum(:last_delivery_at),
               last_processed_at: FeedbackEvent.maximum(:processed_at),
               counts: counts,
             }
    end

    def index
      page = [params[:page].to_i, 0].max
      scope = filtered_scope
      total = scope.count
      events = scope.order(id: :desc).offset(page * PAGE_SIZE).limit(PAGE_SIZE).includes(:user)

      render json: {
               events: serialize_data(events, FeedbackEventSerializer, root: false),
               total: total,
               page: page,
               page_size: PAGE_SIZE,
             }
    end

    def show
      render_serialized(FeedbackEvent.find(params[:id]), FeedbackEventSerializer, root: "event")
    end

    def reprocess
      if !SiteSetting.plunk_feedback_enabled
        return render_json_error(I18n.t("discourse_plunk.errors.disabled"), status: 422)
      end

      event = Processor.process(FeedbackEvent.find(params[:id]), trigger: :admin)
      render_serialized(event, FeedbackEventSerializer, root: "event")
    end

    private

    def counts
      by_status = FeedbackEvent.group(:status).count
      {
        pending: by_status.values_at("received", "processing").compact.sum,
        retrying: FeedbackEvent.where(status: "failed").where.not(next_attempt_at: nil).count,
        failed: FeedbackEvent.where(status: "failed", next_attempt_at: nil).count,
        unmatched: by_status["unmatched"].to_i,
        conflict: by_status["conflict"].to_i,
        processed: by_status["processed"].to_i,
        identity_conflicts: FeedbackEvent.where("identity_conflict_count > 0").count,
      }
    end

    def filtered_scope
      scope = FeedbackEvent.all
      status = params[:status].to_s
      if status == "retrying"
        scope = scope.where(status: "failed").where.not(next_attempt_at: nil)
      elsif status == "pending"
        scope = scope.where(status: %w[received processing])
      elsif FeedbackEvent::STATUSES.include?(status)
        scope = scope.where(status: status)
      end

      kind = params[:kind].to_s
      scope = scope.where(kind: kind) if FeedbackEvent::KINDS.include?(kind)

      query = params[:q].to_s.strip.truncate(320, omission: "")
      return scope if query.blank?

      clauses = [
        "discourse_plunk_feedback_events.recipient ILIKE :like",
        "discourse_plunk_feedback_events.workflow_id = :exact",
        "discourse_plunk_feedback_events.execution_id = :exact",
        "discourse_plunk_feedback_events.plunk_email_id = :exact",
        "discourse_plunk_feedback_events.provider_message_id = :exact",
        "discourse_plunk_feedback_events.user_id IN (SELECT id FROM users WHERE username_lower = :username)",
      ]
      values = {
        like: "%#{ActiveRecord::Base.sanitize_sql_like(query.downcase)}%",
        exact: query,
        username: query.delete_prefix("@").downcase,
      }
      if query.match?(/\A#?\d{1,18}\z/)
        clauses << "discourse_plunk_feedback_events.id = :id"
        values[:id] = query.delete_prefix("#").to_i
      end

      scope.where(clauses.join(" OR "), values)
    end
  end
end
