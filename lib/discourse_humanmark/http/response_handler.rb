# frozen_string_literal: true

module DiscourseHumanmark
  module Http
    class ResponseHandler
      def self.handle(response)
        case response.status
        when 200, 201
          handle_success(response)
        when 400
          handle_bad_request(response)
        when 401
          handle_unauthorized(response)
        when 422
          handle_unprocessable_entity(response)
        when 429
          handle_rate_limit(response)
        when 500..599
          handle_server_error(response)
        else
          handle_unexpected_status(response)
        end
      end

      def self.handle_success(response)
        if response.body.nil? || response.body.empty?
          Rails.logger.debug("[Humanmark] API success")
          return { success: true, data: {} }
        end

        data = JSON.parse(response.body)
        Rails.logger.debug("[Humanmark] API success") if SiteSetting.humanmark_debug_mode
        { success: true, data: data }
      rescue JSON::ParserError => e
        Rails.logger.error("[Humanmark] Invalid JSON response: error=#{e.message}")
        { success: false, error: I18n.t("humanmark.invalid_response") }
      end

      def self.handle_bad_request(response)
        error = parse_error_message(response)
        Rails.logger.warn("[Humanmark] Bad request: error=#{error}")
        { success: false, error: error }
      end

      def self.handle_unauthorized(_response)
        Rails.logger.error("[Humanmark] Unauthorized - check API credentials")
        { success: false, error: I18n.t("humanmark.unauthorized") }
      end

      def self.handle_unprocessable_entity(response)
        error = parse_error_message(response)
        Rails.logger.warn("[Humanmark] Validation error: error=#{error}")
        { success: false, error: error }
      end

      def self.handle_rate_limit(response)
        retry_after = response.headers["Retry-After"]
        Rails.logger.warn("[Humanmark] Rate limited: retry_after=#{retry_after}")
        { success: false, error: I18n.t("humanmark.rate_limited") }
      end

      def self.handle_server_error(response)
        Rails.logger.error("[Humanmark] Server error: status=#{response.status}")
        { success: false, error: I18n.t("humanmark.server_error") }
      end

      def self.handle_unexpected_status(response)
        Rails.logger.error("[Humanmark] Unexpected status: status=#{response.status}")
        { success: false, error: I18n.t("humanmark.unexpected_error") }
      end

      def self.parse_error_message(response)
        data = parse_json(response.body)
        data["error"] || data["message"] || I18n.t("humanmark.unknown_error")
      rescue StandardError
        I18n.t("humanmark.unknown_error")
      end

      def self.parse_json(body)
        return {} if body.nil?

        JSON.parse(body)
      rescue JSON::ParserError
        {}
      end
    end
  end
end
