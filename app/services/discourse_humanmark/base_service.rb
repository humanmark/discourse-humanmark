# frozen_string_literal: true

module DiscourseHumanmark
  class BaseService
    include ActiveModel::Model
    include ActiveModel::Validations

    class ServiceError < StandardError; end

    def self.call(params = {})
      new(params).call
    end

    def call
      return error_result(errors.full_messages.join(", ")) unless valid?

      begin
        execute
      rescue ServiceError => e
        error_result(e.message)
      rescue StandardError => e
        Rails.logger.error("[Humanmark] Service error: service=#{self.class.name} error=#{e.message}")
        Rails.logger.debug(e.backtrace.join("\n")) if SiteSetting.humanmark_debug_mode
        error_result(I18n.t("humanmark.unexpected_error"))
      end
    end

    private

    def execute
      raise NotImplementedError, "Subclasses must implement #execute"
    end

    def success_result(data = {})
      { success: true, **data }
    end

    def error_result(message, data = {})
      { success: false, error: message, **data }
    end
  end
end
