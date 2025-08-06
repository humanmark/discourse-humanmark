# frozen_string_literal: true

module DiscourseHumanmark
  class VerificationService < BaseService
    attr_accessor :context, :user, :receipt

    validates :context, presence: true, inclusion: { in: Verification::VerificationRequirements::CONTEXT_TO_SETTING.keys }

    def execute
      # Check if verification is required
      return success_result(verified: true, required: false) unless verification_required?

      # If no receipt provided, verification fails
      return error_result(I18n.t("humanmark.verification_required")) if receipt.blank?

      # Validate the receipt and complete the flow
      process_verification
    end

    private

    def verification_required?
      Verification::VerificationRequirements.verification_required?(context: context, user: user, emit_events: true)
    end

    def process_verification
      # Validate the receipt
      receipt_result = validate_receipt
      return receipt_result unless receipt_result[:success]

      # Complete the flow and trigger events
      complete_verification_flow(receipt_result[:challenge])
    end

    def validate_receipt
      ReceiptService.call(receipt: receipt, context: context)
    end

    def complete_verification_flow(challenge)
      flow_result = FlowService.call(
        action: :complete,
        challenge: challenge,
        user: user,
        context: context
      )

      handle_flow_result(flow_result)
    end

    def handle_flow_result(flow_result)
      if flow_result[:success]
        trigger_success_event(flow_result[:flow])
        success_result(verified: true, flow_id: flow_result[:flow].id)
      else
        trigger_failure_event(flow_result[:error])
        error_result(flow_result[:error])
      end
    end

    def trigger_success_event(flow)
      DiscourseEvent.trigger(
        :humanmark_verification_completed,
        user_id: user&.id,
        context: context,
        flow_id: flow.id,
        anonymous: user.nil?
      )
    end

    def trigger_failure_event(error)
      DiscourseEvent.trigger(
        :humanmark_verification_failed,
        user_id: user&.id,
        context: context,
        error: error,
        anonymous: user.nil?
      )
    end
  end
end
