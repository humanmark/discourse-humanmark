# frozen_string_literal: true

RSpec.describe DiscourseHumanmark::Integrations::Content do
  describe ".any_content_protection_enabled?" do
    it "returns true when posts protection is enabled" do
      SiteSetting.humanmark_protect_posts = true
      SiteSetting.humanmark_protect_topics = false
      SiteSetting.humanmark_protect_messages = false

      expect(described_class.any_content_protection_enabled?).to be true
    end

    it "returns true when topics protection is enabled" do
      SiteSetting.humanmark_protect_posts = false
      SiteSetting.humanmark_protect_topics = true
      SiteSetting.humanmark_protect_messages = false

      expect(described_class.any_content_protection_enabled?).to be true
    end

    it "returns true when messages protection is enabled" do
      SiteSetting.humanmark_protect_posts = false
      SiteSetting.humanmark_protect_topics = false
      SiteSetting.humanmark_protect_messages = true

      expect(described_class.any_content_protection_enabled?).to be true
    end

    it "returns true when multiple protections are enabled" do
      SiteSetting.humanmark_protect_posts = true
      SiteSetting.humanmark_protect_topics = true
      SiteSetting.humanmark_protect_messages = true

      expect(described_class.any_content_protection_enabled?).to be true
    end

    it "returns false when all protections are disabled" do
      SiteSetting.humanmark_protect_posts = false
      SiteSetting.humanmark_protect_topics = false
      SiteSetting.humanmark_protect_messages = false

      expect(described_class.any_content_protection_enabled?).to be false
    end
  end

  describe ".determine_content_type" do
    let(:topic) { Fabricate(:topic) }
    let(:first_post) { Fabricate(:post, topic: topic, post_number: 1) }
    let(:reply_post) { Fabricate(:post, topic: topic, post_number: 2) }
    let(:pm_topic) { Fabricate(:private_message_topic) }
    let(:pm_first_post) { Fabricate(:post, topic: pm_topic, post_number: 1) }
    let(:pm_reply_post) { Fabricate(:post, topic: pm_topic, post_number: 2) }

    context "with regular posts" do
      it "returns :post for replies when post protection is enabled" do
        SiteSetting.humanmark_protect_posts = true
        opts = { topic_id: topic.id }
        expect(described_class.determine_content_type(reply_post, opts)).to eq(:post)
      end

      it "returns nil for replies when post protection is disabled" do
        SiteSetting.humanmark_protect_posts = false
        opts = { topic_id: topic.id }
        expect(described_class.determine_content_type(reply_post, opts)).to be_nil
      end
    end

    context "with topic creation" do
      it "returns :topic for new topic when topic protection is enabled" do
        SiteSetting.humanmark_protect_topics = true
        SiteSetting.humanmark_protect_messages = false
        opts = { archetype: "regular" }
        expect(described_class.determine_content_type(first_post, opts)).to eq(:topic)
      end

      it "returns nil for new topic when topic protection is disabled" do
        SiteSetting.humanmark_protect_topics = false
        SiteSetting.humanmark_protect_messages = false
        opts = { archetype: "regular" }
        expect(described_class.determine_content_type(first_post, opts)).to be_nil
      end
    end

    context "with private messages" do
      it "returns :message for new PM when message protection is enabled" do
        SiteSetting.humanmark_protect_messages = true
        SiteSetting.humanmark_protect_topics = false
        opts = { archetype: Archetype.private_message }
        expect(described_class.determine_content_type(pm_first_post, opts)).to eq(:message)
      end

      it "returns nil for new PM when message protection is disabled" do
        SiteSetting.humanmark_protect_messages = false
        SiteSetting.humanmark_protect_topics = false
        opts = { archetype: Archetype.private_message }
        expect(described_class.determine_content_type(pm_first_post, opts)).to be_nil
      end

      it "returns :post for PM replies when post protection is enabled" do
        SiteSetting.humanmark_protect_posts = true
        opts = { topic_id: pm_topic.id }
        expect(described_class.determine_content_type(pm_reply_post, opts)).to eq(:post)
      end

      it "returns nil for PM replies when post protection is disabled" do
        SiteSetting.humanmark_protect_posts = false
        opts = { topic_id: pm_topic.id }
        expect(described_class.determine_content_type(pm_reply_post, opts)).to be_nil
      end
    end

    context "with priority handling" do
      it "returns message for new PM when both protections enabled" do
        SiteSetting.humanmark_protect_messages = true
        SiteSetting.humanmark_protect_topics = true
        opts = { archetype: Archetype.private_message }
        expect(described_class.determine_content_type(pm_first_post, opts)).to eq(:message)
      end

      it "returns topic for new topic when both protections enabled" do
        SiteSetting.humanmark_protect_messages = true
        SiteSetting.humanmark_protect_topics = true
        opts = { archetype: "regular" }
        expect(described_class.determine_content_type(first_post, opts)).to eq(:topic)
      end
    end

    context "with edge cases" do
      it "handles new topic creation during before_create_post hook" do
        post_without_topic = Fabricate.build(:post)
        post_without_topic.topic = nil
        post_without_topic.post_number = nil
        SiteSetting.humanmark_protect_topics = true

        # Simulating new topic creation (no topic_id in opts)
        opts = { archetype: "regular" }
        expect { described_class.determine_content_type(post_without_topic, opts) }.not_to raise_error
        expect(described_class.determine_content_type(post_without_topic, opts)).to eq(:topic)
      end

      it "handles reply with topic_id in opts" do
        SiteSetting.humanmark_protect_posts = true
        opts = { topic_id: 123 }
        expect(described_class.determine_content_type(reply_post, opts)).to eq(:post)
      end
    end
  end

  describe ".private_message?" do
    it "returns true for private message posts" do
      pm_topic = Fabricate(:private_message_topic)
      pm_post = Fabricate(:post, topic: pm_topic)
      expect(described_class.private_message?(pm_post)).to be true
    end

    it "returns false for regular topic posts" do
      topic = Fabricate(:topic)
      post = Fabricate(:post, topic: topic)
      expect(described_class.private_message?(post)).to be false
    end

    it "returns false for posts with nil topic" do
      post = Fabricate.build(:post)
      post.topic = nil
      expect(described_class.private_message?(post)).to be false
    end
  end

  describe ".register!" do
    it "logs debug message when debug mode is enabled and protection is enabled" do
      SiteSetting.humanmark_protect_posts = true
      SiteSetting.humanmark_debug_mode = true
      allow(Rails.logger).to receive(:debug)

      described_class.register!

      expect(Rails.logger).to have_received(:debug).with("[Humanmark] Content verification registered")
    end

    it "logs debug message when content protection is enabled" do
      SiteSetting.humanmark_protect_posts = true
      SiteSetting.humanmark_debug_mode = false
      allow(Rails.logger).to receive(:debug)

      described_class.register!

      expect(Rails.logger).to have_received(:debug).with("[Humanmark] Content verification registered")
    end

    it "does not register when all protections are disabled" do
      SiteSetting.humanmark_protect_posts = false
      SiteSetting.humanmark_protect_topics = false
      SiteSetting.humanmark_protect_messages = false
      allow(Rails.logger).to receive(:debug)

      described_class.register!

      expect(Rails.logger).not_to have_received(:debug)
    end
  end
end
