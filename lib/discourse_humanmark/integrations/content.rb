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

      def self.determine_content_type(post)
        return :post if !post.is_first_post? && SiteSetting.humanmark_protect_posts
        return nil unless post.is_first_post?
        return :message if private_message?(post) && SiteSetting.humanmark_protect_messages
        return :topic if SiteSetting.humanmark_protect_topics

        nil
      end

      def self.private_message?(post)
        post.topic&.archetype == Archetype.private_message
      end
    end
  end
end
