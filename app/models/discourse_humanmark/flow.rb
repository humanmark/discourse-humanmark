# frozen_string_literal: true

module DiscourseHumanmark
  class Flow < ActiveRecord::Base
    self.table_name = "humanmark_flows"

    validates :challenge, presence: true, uniqueness: true
    validates :token, presence: true
    validates :context, presence: true, inclusion: {
      in: %w[post topic message]
    }
    validates :status, inclusion: { in: %w[pending completed expired failed] }

    # Enable optimistic locking
    self.locking_column = :lock_version

    scope :pending, -> { where(status: "pending") }
    scope :completed, -> { where(status: "completed") }
    scope :expired, -> { where(status: "expired") }
    scope :failed, -> { where(status: "failed") }
    scope :recent_completed_for_user_and_context, lambda { |user_id, context, minutes|
      completed
        .where(user_id: user_id, context: context)
        .where("completed_at > ?", minutes.minutes.ago)
        .order(completed_at: :desc)
    }

    EXPIRY_TIME = 1.hour

    def pending?
      status == "pending"
    end

    def completed?
      status == "completed"
    end

    def failed?
      status == "failed"
    end

    def expired?
      return true if status == "expired"
      return false if status == "completed"

      created_at < EXPIRY_TIME.ago
    end

    def complete!
      return false if completed? || expired?

      # Use atomic update to prevent race conditions
      rows_updated = self.class
                         .where(id: id, status: "pending")
                         .update_all(
                           status: "completed",
                           completed_at: Time.current,
                           lock_version: lock_version + 1
                         )

      reload
      rows_updated == 1
    rescue ActiveRecord::StaleObjectError
      # Optimistic locking conflict
      reload
      false
    end

    def self.mark_expired!
      pending.where("created_at < ?", EXPIRY_TIME.ago).update_all(status: "expired")
    end

    def self.recent_verification?(user_id:, context:, minutes:)
      return false if minutes.zero?

      recent_completed_for_user_and_context(user_id, context, minutes).exists?
    end

    def self.minimum_retention_minutes
      # Get the maximum of all reverify periods to ensure we keep flows long enough
      [
        SiteSetting.humanmark_reverify_period_posts,
        SiteSetting.humanmark_reverify_period_topics,
        SiteSetting.humanmark_reverify_period_messages
      ].max
    end

    def self.cleanup_old!
      # Ensure we keep flows for at least as long as the longest reverify period
      configured_retention_days = SiteSetting.humanmark_flow_retention_days
      minimum_retention_minutes = self.minimum_retention_minutes
      minimum_retention_days = (minimum_retention_minutes / 1440.0).ceil

      # Use the greater of configured retention or minimum required for reverify
      actual_retention_days = [configured_retention_days, minimum_retention_days].max
      retention_cutoff = actual_retention_days.days.ago

      transaction do
        # Mark old pending flows as expired (only if they won't be deleted)
        marked = pending
                 .where("created_at < ?", EXPIRY_TIME.ago)
                 .where("created_at >= ?", retention_cutoff)
                 .update_all(status: "expired")

        # Delete all flows older than retention period (regardless of status)
        deleted = where("created_at < ?", retention_cutoff).delete_all

        { marked_expired: marked, deleted: deleted, retention_days_used: actual_retention_days }
      end
    end
  end
end
