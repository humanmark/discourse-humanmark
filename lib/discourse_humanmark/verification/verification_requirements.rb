# frozen_string_literal: true

module DiscourseHumanmark
  module Verification
    module VerificationRequirements
      CONTEXT_TO_SETTING = {
        post: :humanmark_protect_posts,
        topic: :humanmark_protect_topics,
        message: :humanmark_protect_messages
      }.freeze

      CONTEXT_TO_REVERIFY = {
        post: :humanmark_reverify_period_posts,
        topic: :humanmark_reverify_period_topics,
        message: :humanmark_reverify_period_messages
      }.freeze

      def self.verification_required?(context:, user:, emit_events: false)
        return false unless basic_verification_checks_pass?(user, context, emit_events: emit_events)
        return false unless context_protection_enabled?(context)
        return false if recent_verification_bypass?(user, context, emit_events)

        log_verification_required(user, context)
        true
      end

      def self.context_protection_enabled?(context)
        setting_name = CONTEXT_TO_SETTING[context]
        setting_name && SiteSetting.public_send(setting_name)
      end

      def self.recent_verification_bypass?(user, context, emit_events)
        return false unless recent_verification?(user, context)

        log_bypass_event("recent_verification", user, context)
        emit_bypass_event("recent_verification", user, context) if emit_events
        true
      end

      def self.log_verification_required(user, context)
        return unless SiteSetting.humanmark_debug_mode

        Rails.logger.debug("[Humanmark] Verification required: user_id=#{user&.id || 'anonymous'} context=#{context}")
      end

      def self.log_bypass_event(reason, user, context)
        return unless SiteSetting.humanmark_debug_mode

        Rails.logger.debug("[Humanmark] Verification bypassed: reason=#{reason} user_id=#{user&.id || 'anonymous'} context=#{context}")
      end

      def self.emit_bypass_event(reason, user, context)
        DiscourseEvent.trigger(:humanmark_verification_bypassed, user_id: user&.id, context: context, reason: reason)
      end

      def self.basic_verification_checks_pass?(user, context, emit_events: false)
        return false unless SiteSetting.humanmark_enabled
        return false if staff_bypass?(user, context, emit_events)
        return false if trust_level_bypass?(user, context, emit_events)

        true
      end

      def self.staff_bypass?(user, context, emit_events)
        return false unless user&.staff? && SiteSetting.humanmark_bypass_staff

        Rails.logger.info("[Humanmark] Verification bypassed: reason=staff user_id=#{user.id} context=#{context}")
        emit_bypass_event("staff", user, context) if emit_events
        true
      end

      def self.trust_level_bypass?(user, context, emit_events)
        return false unless user && user.trust_level >= SiteSetting.humanmark_bypass_trust_level

        Rails.logger.info("[Humanmark] Verification bypassed: reason=trust_level user_id=#{user.id} trust_level=#{user.trust_level} context=#{context}")
        DiscourseEvent.trigger(:humanmark_verification_bypassed, user_id: user.id, context: context, reason: "trust_level", trust_level: user.trust_level) if emit_events
        true
      end

      def self.recent_verification?(user, context)
        return false unless user

        reverify_setting = CONTEXT_TO_REVERIFY[context]
        return false unless reverify_setting

        reverify_minutes = SiteSetting.public_send(reverify_setting)
        return false if reverify_minutes.zero?

        has_recent = Flow.recent_verification?(
          user_id: user.id,
          context: context.to_s,
          minutes: reverify_minutes
        )

        Rails.logger.debug("[Humanmark] Recent verification found: user_id=#{user.id} context=#{context} minutes=#{reverify_minutes}") if has_recent && SiteSetting.humanmark_debug_mode

        has_recent
      end
    end
  end
end
