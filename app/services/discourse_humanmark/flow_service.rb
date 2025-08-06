# frozen_string_literal: true

module DiscourseHumanmark
  class FlowService < BaseService
    attr_accessor :action, :context, :user, :challenge

    validates :action, presence: true, inclusion: { in: %i[create complete find] }
    validates :context, presence: true, inclusion: { in: %i[post topic message] }, if: -> { action == :create }
    validates :challenge, presence: true, if: -> { %i[complete find].include?(action) }

    def execute
      case action
      when :create
        create_flow
      when :complete
        complete_flow
      when :find
        find_flow
      end
    end

    private

    def create_flow
      challenge_result = ChallengeService.call
      return challenge_result unless challenge_result[:success]

      flow = create_flow_record(challenge_result)

      Rails.logger.debug("[Humanmark] Flow created: challenge=#{flow.challenge[0..7]}... context=#{context}") if SiteSetting.humanmark_debug_mode

      success_result(flow: flow, token: flow.token)
    rescue ActiveRecord::RecordInvalid => e
      error_result(I18n.t("humanmark.flow_creation_failed", error: e.message))
    end

    def create_flow_record(challenge_result)
      flow = Flow.create!(
        challenge: challenge_result[:challenge],
        token: challenge_result[:token],
        context: context,
        user_id: user&.id,
        status: "pending",
        created_at: Time.current
      )

      Rails.logger.info("[Humanmark] Flow created: flow_id=#{flow.id} user_id=#{user&.id || 'anonymous'} context=#{context}")
      # Trigger event for monitoring
      DiscourseEvent.trigger(:humanmark_flow_created, flow_id: flow.id, user_id: user&.id, context: context, anonymous: user.nil?)

      flow
    end

    def complete_flow
      DistributedMutex.synchronize("humanmark_flow_#{challenge}", validity: 10) do
        flow = Flow.find_by(challenge: challenge)

        validation_result = validate_flow_completion(flow)
        return validation_result unless validation_result[:success]

        complete_flow_record(flow)
      end
    rescue StandardError => e
      Rails.logger.error("[Humanmark] Flow completion error: #{e.message}")
      error_result(I18n.t("humanmark.flow_completion_failed"))
    end

    def validate_flow_completion(flow)
      return flow_not_found_error unless flow

      user_validation = validate_flow_user(flow)
      return user_validation unless user_validation[:success]

      context_validation = validate_flow_context(flow)
      return context_validation unless context_validation[:success]

      status_validation = validate_flow_status(flow)
      return status_validation unless status_validation[:success]

      success_result
    end

    def flow_not_found_error
      Rails.logger.debug("[Humanmark] Flow not found: challenge=#{challenge[0..7]}...") if SiteSetting.humanmark_debug_mode
      error_result(I18n.t("humanmark.flow_not_found"))
    end

    def validate_flow_user(flow)
      # Validate user matches (anonymous flows can only be used by anonymous users)
      if flow.user_id.present? && flow.user_id != user&.id
        Rails.logger.warn("[Humanmark] User mismatch: challenge=#{challenge[0..7]}... expected_user=#{flow.user_id} actual_user=#{user&.id}")
        return error_result(I18n.t("humanmark.flow_not_found"))
      end

      if flow.user_id.nil? && user.present?
        Rails.logger.warn("[Humanmark] Anonymous flow misuse: challenge=#{challenge[0..7]}... user=#{user.id}")
        return error_result(I18n.t("humanmark.flow_not_found"))
      end

      success_result
    end

    def validate_flow_context(flow)
      # Validate context matches if provided
      if context.present? && flow.context != context.to_s
        Rails.logger.warn("[Humanmark] Context mismatch: challenge=#{challenge[0..7]}... expected=#{flow.context} actual=#{context}")
        return error_result(I18n.t("humanmark.flow_not_found"))
      end

      success_result
    end

    def validate_flow_status(flow)
      if flow.completed?
        Rails.logger.info("[Humanmark] Flow already completed: challenge=#{challenge[0..7]}... flow_id=#{flow.id}")
        return error_result(I18n.t("humanmark.challenge_already_used"))
      end

      if flow.expired?
        Rails.logger.info("[Humanmark] Flow expired: challenge=#{challenge[0..7]}... created_at=#{flow.created_at}")
        DiscourseEvent.trigger(:humanmark_flow_expired, flow_id: flow.id, user_id: flow.user_id, context: flow.context)
        return error_result(I18n.t("humanmark.flow_expired"))
      end

      success_result
    end

    def complete_flow_record(flow)
      if flow.complete!
        Rails.logger.info("[Humanmark] Flow completed: flow_id=#{flow.id} user_id=#{flow.user_id || 'anonymous'} context=#{flow.context} duration_seconds=#{(Time.current - flow.created_at).round(2)}")
        # Trigger event for monitoring
        DiscourseEvent.trigger(:humanmark_flow_completed, flow_id: flow.id, user_id: flow.user_id, context: flow.context, duration_seconds: (Time.current - flow.created_at).round(2))
        success_result(flow: flow)
      else
        error_result(I18n.t("humanmark.challenge_already_used"))
      end
    end

    def find_flow
      flow = Flow.find_by(challenge: challenge)

      if flow
        success_result(flow: flow)
      else
        error_result(I18n.t("humanmark.flow_not_found"))
      end
    end
  end
end
