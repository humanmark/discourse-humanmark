# frozen_string_literal: true

RSpec.describe DiscourseHumanmark::Verification::VerificationRequirements do
  fab!(:user) { Fabricate(:user, trust_level: 1) }
  fab!(:admin)
  fab!(:moderator)
  fab!(:high_trust_user) { Fabricate(:user, trust_level: 4) }

  before do
    SiteSetting.humanmark_enabled = true
    SiteSetting.humanmark_api_key = "test-key"
    SiteSetting.humanmark_api_secret = "test-secret"
  end

  describe ".verification_required?" do
    context "when plugin is disabled" do
      before { SiteSetting.humanmark_enabled = false }

      it "returns false for all contexts" do
        expect(described_class.verification_required?(context: :post, user: user)).to be false
        expect(described_class.verification_required?(context: :topic, user: user)).to be false
        expect(described_class.verification_required?(context: :message, user: user)).to be false
      end
    end

    context "with post protection" do
      before do
        SiteSetting.humanmark_protect_posts = true
        SiteSetting.humanmark_protect_topics = false
        SiteSetting.humanmark_protect_messages = false
      end

      it "requires verification for posts when enabled" do
        expect(described_class.verification_required?(context: :post, user: user)).to be true
      end

      it "does not require verification for topics when disabled" do
        expect(described_class.verification_required?(context: :topic, user: user)).to be false
      end

      it "does not require verification for messages when disabled" do
        expect(described_class.verification_required?(context: :message, user: user)).to be false
      end
    end

    context "with topic protection" do
      before do
        SiteSetting.humanmark_protect_posts = false
        SiteSetting.humanmark_protect_topics = true
        SiteSetting.humanmark_protect_messages = false
      end

      it "requires verification for topics when enabled" do
        expect(described_class.verification_required?(context: :topic, user: user)).to be true
      end

      it "does not require verification for posts when disabled" do
        expect(described_class.verification_required?(context: :post, user: user)).to be false
      end
    end

    context "with message protection" do
      before do
        SiteSetting.humanmark_protect_posts = false
        SiteSetting.humanmark_protect_topics = false
        SiteSetting.humanmark_protect_messages = true
      end

      it "requires verification for messages when enabled" do
        expect(described_class.verification_required?(context: :message, user: user)).to be true
      end

      it "does not require verification for posts when disabled" do
        expect(described_class.verification_required?(context: :post, user: user)).to be false
      end
    end

    context "with staff bypass" do
      before do
        SiteSetting.humanmark_protect_posts = true
        SiteSetting.humanmark_bypass_staff = true
      end

      it "bypasses verification for admin users" do
        expect(described_class.verification_required?(context: :post, user: admin)).to be false
      end

      it "bypasses verification for moderator users" do
        expect(described_class.verification_required?(context: :post, user: moderator)).to be false
      end

      it "requires verification for regular users" do
        expect(described_class.verification_required?(context: :post, user: user)).to be true
      end

      context "when staff bypass is disabled" do
        before do
          SiteSetting.humanmark_bypass_staff = false
          # Make sure bypass trust level is high so admin trust level doesn't bypass
          SiteSetting.humanmark_bypass_trust_level = 5
        end

        it "requires verification for admin users" do
          expect(described_class.verification_required?(context: :post, user: admin)).to be true
        end

        it "requires verification for moderator users" do
          expect(described_class.verification_required?(context: :post, user: moderator)).to be true
        end
      end
    end

    context "with trust level bypass" do
      before do
        SiteSetting.humanmark_protect_posts = true
      end

      it "bypasses verification when user trust level >= bypass level" do
        SiteSetting.humanmark_bypass_trust_level = 1
        expect(described_class.verification_required?(context: :post, user: user)).to be false
      end

      it "requires verification when user trust level < bypass level" do
        SiteSetting.humanmark_bypass_trust_level = 2
        expect(described_class.verification_required?(context: :post, user: user)).to be true
      end

      it "requires verification for all users when bypass level is 5" do
        SiteSetting.humanmark_bypass_trust_level = 5
        expect(described_class.verification_required?(context: :post, user: high_trust_user)).to be true
      end

      it "bypasses high trust users when level is 4" do
        SiteSetting.humanmark_bypass_trust_level = 4
        expect(described_class.verification_required?(context: :post, user: high_trust_user)).to be false
      end

      it "requires verification for trust level 3 when bypass is 4" do
        SiteSetting.humanmark_bypass_trust_level = 4
        user_tl3 = Fabricate(:user, trust_level: 3)
        expect(described_class.verification_required?(context: :post, user: user_tl3)).to be true
      end
    end

    context "with anonymous users" do
      before do
        SiteSetting.humanmark_protect_posts = true
      end

      it "requires verification for anonymous users" do
        expect(described_class.verification_required?(context: :post, user: nil)).to be true
      end

      it "does not bypass for anonymous even with trust level 0 bypass" do
        SiteSetting.humanmark_bypass_trust_level = 0
        expect(described_class.verification_required?(context: :post, user: nil)).to be true
      end
    end

    context "with recent verification" do
      before do
        SiteSetting.humanmark_protect_posts = true
        SiteSetting.humanmark_reverify_period_posts = 30
      end

      it "does not require verification within reverify period" do
        # Create a recent completed flow
        DiscourseHumanmark::Flow.create!(
          challenge: "recent-challenge",
          token: "recent-token",
          context: "post",
          user_id: user.id,
          status: "completed",
          completed_at: 10.minutes.ago
        )

        expect(described_class.verification_required?(context: :post, user: user)).to be false
      end

      it "requires verification after reverify period expires" do
        # Create an old completed flow
        DiscourseHumanmark::Flow.create!(
          challenge: "old-challenge",
          token: "old-token",
          context: "post",
          user_id: user.id,
          status: "completed",
          completed_at: 45.minutes.ago
        )

        expect(described_class.verification_required?(context: :post, user: user)).to be true
      end

      it "always requires verification when reverify period is 0" do
        SiteSetting.humanmark_reverify_period_posts = 0

        # Even with a recent completed flow
        DiscourseHumanmark::Flow.create!(
          challenge: "recent-challenge",
          token: "recent-token",
          context: "post",
          user_id: user.id,
          status: "completed",
          completed_at: 1.minute.ago
        )

        expect(described_class.verification_required?(context: :post, user: user)).to be true
      end

      it "tracks verification separately per context" do
        SiteSetting.humanmark_protect_topics = true
        SiteSetting.humanmark_reverify_period_topics = 60

        # Create recent post verification
        DiscourseHumanmark::Flow.create!(
          challenge: "post-challenge",
          token: "post-token",
          context: "post",
          user_id: user.id,
          status: "completed",
          completed_at: 10.minutes.ago
        )

        # Post context should not require verification (within 30 min period)
        expect(described_class.verification_required?(context: :post, user: user)).to be false

        # Topic context should still require verification (no recent topic verification)
        expect(described_class.verification_required?(context: :topic, user: user)).to be true
      end
    end

    context "with invalid context" do
      before do
        SiteSetting.humanmark_protect_posts = true
      end

      it "returns false for unknown context" do
        expect(described_class.verification_required?(context: :invalid, user: user)).to be false
      end

      it "returns false for nil context" do
        expect(described_class.verification_required?(context: nil, user: user)).to be false
      end
    end
  end

  describe ".basic_verification_checks_pass?" do
    it "returns false when plugin is disabled" do
      SiteSetting.humanmark_enabled = false
      expect(described_class.basic_verification_checks_pass?(user, :post)).to be false
    end

    it "returns false for staff when bypass is enabled" do
      SiteSetting.humanmark_bypass_staff = true
      expect(described_class.basic_verification_checks_pass?(admin, :post)).to be false
    end

    it "returns false when user trust level >= bypass level" do
      SiteSetting.humanmark_bypass_trust_level = 1
      expect(described_class.basic_verification_checks_pass?(user, :post)).to be false
    end

    it "returns true when no bypass conditions are met" do
      SiteSetting.humanmark_bypass_staff = false
      SiteSetting.humanmark_bypass_trust_level = 5
      expect(described_class.basic_verification_checks_pass?(user, :post)).to be true
    end

    it "returns true for anonymous users" do
      expect(described_class.basic_verification_checks_pass?(nil, :post)).to be true
    end
  end

  describe ".recent_verification?" do
    it "returns false for anonymous users" do
      expect(described_class.recent_verification?(nil, :post)).to be false
    end

    it "returns false when no reverify setting exists" do
      expect(described_class.recent_verification?(user, :invalid_context)).to be false
    end

    it "returns false when reverify period is 0" do
      SiteSetting.humanmark_reverify_period_posts = 0
      expect(described_class.recent_verification?(user, :post)).to be false
    end

    it "returns true when recent verification exists" do
      SiteSetting.humanmark_reverify_period_posts = 30
      DiscourseHumanmark::Flow.create!(
        challenge: "recent",
        token: "token",
        context: "post",
        user_id: user.id,
        status: "completed",
        completed_at: 10.minutes.ago
      )

      expect(described_class.recent_verification?(user, :post)).to be true
    end

    it "returns false when verification is too old" do
      SiteSetting.humanmark_reverify_period_posts = 30
      DiscourseHumanmark::Flow.create!(
        challenge: "old",
        token: "token",
        context: "post",
        user_id: user.id,
        status: "completed",
        completed_at: 45.minutes.ago
      )

      expect(described_class.recent_verification?(user, :post)).to be false
    end
  end
end
