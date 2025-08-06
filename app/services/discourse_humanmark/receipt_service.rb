# frozen_string_literal: true

module DiscourseHumanmark
  class ReceiptService < BaseService
    attr_accessor :receipt, :context

    validates :receipt, presence: true
    validates :context, presence: true

    def execute
      # Verify JWT signature
      payload = Verification::JwtVerifier.verify(
        receipt,
        SiteSetting.humanmark_api_secret
      )

      challenge = payload["sub"].to_s # Convert to string in case it's an integer
      return error_result(I18n.t("humanmark.invalid_receipt")) if challenge.blank?

      Rails.logger.debug("[Humanmark] Receipt verified: challenge=#{challenge[0..7]}...") if SiteSetting.humanmark_debug_mode

      success_result(
        challenge: challenge,
        payload: payload
      )
    rescue Verification::JwtVerifier::InvalidTokenError => e
      Rails.logger.warn("[Humanmark] Invalid receipt: error=#{e.message}")
      error_result(I18n.t("humanmark.invalid_receipt"))
    end
  end
end
