# frozen_string_literal: true

module DiscourseHumanmark
  class ChallengeService < BaseService
    def execute
      validate_configuration!

      domain = SiteSetting.humanmark_domain.presence || Discourse.current_hostname

      Rails.logger.debug("[Humanmark] Creating challenge: domain=#{domain}")

      response = Http::ApiClient.post("/api/v1/challenge/create", {
                                        domain: domain
                                      })

      if response[:success]
        success_result(
          challenge: response[:data]["challenge"],
          token: response[:data]["token"]
        )
      else
        error_result(response[:error])
      end
    end

    private

    def validate_configuration!
      raise ServiceError, I18n.t("humanmark.api_key_missing") if SiteSetting.humanmark_api_key.blank?

      return if SiteSetting.humanmark_api_secret.present?

      raise ServiceError, I18n.t("humanmark.api_secret_missing")
    end
  end
end
