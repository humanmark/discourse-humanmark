# frozen_string_literal: true

module Jobs
  class HumanmarkCleanup < ::Jobs::Scheduled
    every 1.day

    def execute(_args)
      return unless SiteSetting.humanmark_enabled

      # Clean up old flows
      result = DiscourseHumanmark::Flow.cleanup_old!

      if result[:deleted].positive? || result[:marked_expired].positive?
        Rails.logger.info(
          "[Humanmark] Cleanup completed: marked_expired=#{result[:marked_expired]} " \
          "deleted=#{result[:deleted]} retention_days=#{result[:retention_days_used]}"
        )
      end

      # Clean up old PluginStore metrics (keep same retention as flows)
      cleanup_plugin_store_metrics(result[:retention_days_used])
    rescue StandardError => e
      Rails.logger.error("[Humanmark] Cleanup job failed: error=#{e.message}")
      raise
    end

    private

    def cleanup_plugin_store_metrics(retention_days)
      cutoff_date = retention_days.days.ago.to_date

      # Get all keys from PluginStore for our plugin
      prefix_patterns = %w[
        flows_created flows_completed flows_expired
        verifications_completed verifications_failed verifications_bypassed
        rate_limits_hit rate_limit_ bypass_reason_ context_
      ]

      deleted_count = 0

      prefix_patterns.each do |prefix|
        # Find and delete old entries
        ::PluginStore.list_keys(DiscourseHumanmark::PLUGIN_NAME).each do |key|
          next unless key.start_with?(prefix)

          # Extract date from key (format: "prefix:YYYY-MM-DD")
          date_match = key.match(/:(\d{4}-\d{2}-\d{2})$/)
          next unless date_match

          key_date = Date.parse(date_match[1])
          if key_date < cutoff_date
            ::PluginStore.remove(DiscourseHumanmark::PLUGIN_NAME, key)
            deleted_count += 1
          end
        end
      end

      Rails.logger.info("[Humanmark] PluginStore cleanup: deleted_keys=#{deleted_count} cutoff_date=#{cutoff_date}") if deleted_count.positive?
    rescue StandardError => e
      Rails.logger.error("[Humanmark] PluginStore cleanup failed: error=#{e.message}")
      # Don't raise - we don't want to fail the whole job if metric cleanup fails
    end
  end
end
