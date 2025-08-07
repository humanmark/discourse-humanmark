# frozen_string_literal: true

module DiscourseHumanmark
  module Integrations
    class Content < Base
      def self.register!
        return unless any_content_protection_enabled?

        Rails.logger.debug("[Humanmark] Content verification registered")
      end

      def self.any_content_protection_enabled?
        SiteSetting.humanmark_protect_posts ||
          SiteSetting.humanmark_protect_topics ||
          SiteSetting.humanmark_protect_messages
      end

      def self.determine_content_type(_post, opts = {})
        # Check if it's a reply (has topic_id in opts)
        if opts[:topic_id].present?
          # It's a reply to an existing topic or PM
          return SiteSetting.humanmark_protect_posts ? :post : nil
        end

        # It's a new topic or PM (no topic_id)
        if opts[:archetype] == Archetype.private_message
          return SiteSetting.humanmark_protect_messages ? :message : nil
        end

        # Regular new topic
        SiteSetting.humanmark_protect_topics ? :topic : nil
      end

      def self.private_message?(post)
        post.topic&.archetype == Archetype.private_message
      end
    end
  end
end
