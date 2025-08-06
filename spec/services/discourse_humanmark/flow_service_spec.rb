# frozen_string_literal: true

RSpec.describe DiscourseHumanmark::FlowService, :humanmark, type: :service do
  let(:user) { Fabricate(:user, trust_level: 1) }

  before do
    SiteSetting.humanmark_enabled = true
    SiteSetting.humanmark_api_key = "test-key"
    SiteSetting.humanmark_api_secret = "test-secret"
  end

  describe "#create" do
    context "when verification is required" do
      before do
        SiteSetting.humanmark_protect_posts = true
        stub_humanmark_api_request(success: true)
      end

      it "creates a new flow" do
        result = described_class.call(action: :create, context: :post, user: user)

        expect(result[:success]).to be true
        flow = result[:flow]
        expect(flow).to be_present
        expect(flow.challenge).to be_present
        expect(flow.token).to be_present
        expect(flow.user_id).to eq(user.id)
        expect(flow.context).to eq("post")
      end

      it "handles API failures gracefully" do
        stub_humanmark_api_request(success: false)

        result = described_class.call(action: :create, context: :post, user: user)
        expect(result[:success]).to be false
        expect(result[:error]).to be_present
      end
    end

    context "when verification is not required" do
      before do
        SiteSetting.humanmark_protect_posts = false
        stub_humanmark_api_request(success: true)
      end

      it "creates flow even when protection disabled" do
        # The FlowService always creates flows when called, regardless of protection settings
        result = described_class.call(action: :create, context: :post, user: user)

        expect(result[:success]).to be true
        expect(result[:flow]).to be_present
        expect(DiscourseHumanmark::Flow.count).to eq(1)
      end
    end

    context "with anonymous users" do
      before do
        SiteSetting.humanmark_protect_posts = true
        stub_humanmark_api_request(success: true)
      end

      it "creates flow with nil user_id for anonymous users" do
        result = described_class.call(action: :create, context: :post, user: nil)

        expect(result[:success]).to be true
        flow = result[:flow]
        expect(flow).to be_present
        expect(flow.user_id).to be_nil
        expect(flow.context).to eq("post")
      end
    end

    context "with bypass rules" do
      before do
        SiteSetting.humanmark_protect_posts = true
      end

      it "creates flow for staff even when bypass enabled" do
        SiteSetting.humanmark_bypass_staff = true
        staff_user = Fabricate(:admin)
        stub_humanmark_api_request(success: true)

        # FlowService always creates flows when called, bypass rules are checked elsewhere
        result = described_class.call(action: :create, context: :post, user: staff_user)
        expect(result[:success]).to be true
        expect(result[:flow]).to be_present
      end

      it "creates flow for high trust users even when bypass enabled" do
        SiteSetting.humanmark_bypass_trust_level = 2
        trusted_user = Fabricate(:user, trust_level: 3)
        stub_humanmark_api_request(success: true)

        # FlowService always creates flows when called, bypass rules are checked elsewhere
        result = described_class.call(action: :create, context: :post, user: trusted_user)
        expect(result[:success]).to be true
        expect(result[:flow]).to be_present
      end

      it "creates flow when trust level bypass is set to 5" do
        SiteSetting.humanmark_bypass_trust_level = 5
        stub_humanmark_api_request(success: true)
        high_trust_user = Fabricate(:user, trust_level: 4)

        result = described_class.call(action: :create, context: :post, user: high_trust_user)
        expect(result[:success]).to be true
        expect(result[:flow]).to be_present
      end
    end

    context "with reverify periods" do
      before do
        SiteSetting.humanmark_protect_posts = true
        SiteSetting.humanmark_reverify_period_posts = 30
      end

      it "creates flow even if recently verified" do
        create_flow(
          user_id: user.id,
          context: "post",
          status: "completed",
          completed_at: 10.minutes.ago
        )
        stub_humanmark_api_request(success: true)

        # FlowService always creates flows when called, reverify logic is checked elsewhere
        result = described_class.call(action: :create, context: :post, user: user)
        expect(result[:success]).to be true
        expect(result[:flow]).to be_present
      end

      it "creates flow if last verification is old" do
        stub_humanmark_api_request(success: true)
        create_flow(
          user_id: user.id,
          context: "post",
          status: "completed",
          completed_at: 45.minutes.ago
        )

        result = described_class.call(action: :create, context: :post, user: user)
        expect(result[:success]).to be true
        expect(result[:flow]).to be_present
      end

      it "always creates flow when reverify period is 0" do
        SiteSetting.humanmark_reverify_period_posts = 0
        stub_humanmark_api_request(success: true)
        create_flow(
          user_id: user.id,
          context: "post",
          status: "completed",
          completed_at: 1.minute.ago
        )

        result = described_class.call(action: :create, context: :post, user: user)
        expect(result[:success]).to be true
        expect(result[:flow]).to be_present
      end
    end
  end

  describe "#complete" do
    let(:flow) { create_flow(challenge: "test-challenge", status: "pending") }

    it "completes a pending flow" do
      result = described_class.call(action: :complete, challenge: flow.challenge)

      expect(result[:success]).to be true
      expect(flow.reload.completed?).to be true
    end

    it "prevents double completion" do
      described_class.call(action: :complete, challenge: flow.challenge)

      result = described_class.call(action: :complete, challenge: flow.challenge)
      expect(result[:success]).to be false
      expect(result[:error]).to be_present
    end

    it "handles concurrent completion attempts" do
      results = []
      threads = 3.times.map do
        Thread.new do
          results << described_class.call(action: :complete, challenge: flow.challenge)
        end
      end
      threads.each(&:join)

      successful = results.select { |r| r[:success] }
      expect(successful.count).to eq(1)
    end

    it "fails when flow not found" do
      result = described_class.call(action: :complete, challenge: "nonexistent")
      expect(result[:success]).to be false
      expect(result[:error]).to be_present
    end
  end

  describe "#find" do
    let(:flow) { create_flow(challenge: "test-challenge") }

    it "finds existing flow by challenge" do
      result = described_class.call(action: :find, challenge: flow.challenge)

      expect(result[:success]).to be true
      expect(result[:flow]).to eq(flow)
    end

    it "returns error when flow not found" do
      result = described_class.call(action: :find, challenge: "nonexistent")

      expect(result[:success]).to be false
      expect(result[:error]).to be_present
    end
  end
end
