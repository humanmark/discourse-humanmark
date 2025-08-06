# frozen_string_literal: true

module DiscourseHumanmark
  module Integrations
    class Base
      class << self
        def register!
          raise NotImplementedError, "Subclasses must implement .register!"
        end

        def verify_action(context:, user:, receipt:)
          result = VerificationService.call(
            context: context,
            user: user,
            receipt: receipt
          )

          unless result[:success]
            case result[:error]
            when I18n.t("humanmark.verification_required")
              raise Discourse::InvalidAccess, result[:error]
            else
              Rails.logger.error("[Humanmark] Verification failed: #{result[:error]}")
              raise Discourse::InvalidAccess, I18n.t("humanmark.verification_failed")
            end
          end

          result
        end
      end
    end
  end
end
