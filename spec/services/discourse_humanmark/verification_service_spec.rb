# frozen_string_literal: true

RSpec.describe DiscourseHumanmark::VerificationService, :humanmark, type: :service do
  let(:user) { Fabricate(:user) }
  let(:challenge) { "test-challenge-123" }
  let(:flow) { create_flow(challenge: challenge, status: "pending", user_id: user.id, context: "post") }

  before do
    SiteSetting.humanmark_enabled = true
    SiteSetting.humanmark_api_key = "test-key"
    SiteSetting.humanmark_api_secret = "test-secret"
    SiteSetting.humanmark_protect_posts = true
    SiteSetting.humanmark_reverify_period_posts = 0 # Always require verification
  end

  describe "#call" do
    context "when verification not required" do
      it "returns success when protection disabled" do
        SiteSetting.humanmark_protect_posts = false
        result = described_class.call(context: :post, user: user, receipt: nil)
        expect(result[:success]).to be true
        expect(result[:verified]).to be true
        expect(result[:required]).to be false
      end

      it "returns success when user bypassed" do
        SiteSetting.humanmark_bypass_staff = true
        admin = Fabricate(:admin)
        result = described_class.call(context: :post, user: admin, receipt: nil)
        expect(result[:success]).to be true
        expect(result[:verified]).to be true
        expect(result[:required]).to be false
      end
    end

    context "when verification required" do
      let(:valid_receipt) do
        generate_jwt({ sub: challenge }, SiteSetting.humanmark_api_secret)
      end

      before { flow }

      it "verifies successfully with valid receipt" do
        result = described_class.call(receipt: valid_receipt, context: :post, user: user)
        expect(result[:success]).to be true
        expect(result[:verified]).to be true
        expect(flow.reload.completed?).to be true
      end

      it "fails without receipt" do
        result = described_class.call(receipt: nil, context: :post, user: user)
        expect(result[:success]).to be false
        expect(result[:error]).to be_present
      end

      it "fails with invalid receipt" do
        invalid_receipt = generate_jwt({ sub: challenge }, "wrong-secret")
        result = described_class.call(receipt: invalid_receipt, context: :post, user: user)
        expect(result[:success]).to be false
        expect(result[:error]).to be_present
      end

      it "fails when flow not found" do
        receipt = generate_jwt({ sub: "nonexistent" }, SiteSetting.humanmark_api_secret)
        result = described_class.call(receipt: receipt, context: :post, user: user)
        expect(result[:success]).to be false
        expect(result[:error]).to be_present
      end

      it "fails when flow already completed" do
        # Complete the flow and verify it's completed
        expect(flow.complete!).to be true
        expect(flow.reload.status).to eq("completed")

        # Double-check by fetching from DB
        db_flow = DiscourseHumanmark::Flow.find_by(challenge: challenge)
        expect(db_flow.status).to eq("completed")

        # Try to reuse the same receipt
        result = described_class.call(receipt: valid_receipt, context: :post, user: user)
        expect(result[:success]).to be false
        expect(result[:error]).to eq(I18n.t("humanmark.challenge_already_used"))
      end

      it "handles race conditions" do
        # Create a fresh flow for this test
        race_flow = create_flow(challenge: "race-challenge", status: "pending", user_id: user.id)
        race_receipt = generate_jwt({ sub: "race-challenge" }, SiteSetting.humanmark_api_secret)

        completed = []
        winners = []
        threads = 3.times.map do |i|
          Thread.new do
            result = described_class.call(receipt: race_receipt, context: :post, user: user)
            completed << { thread_id: i, success: result[:success], error: result[:error] }
            winners << i if result[:success]
          end
        end
        threads.each(&:join)

        # Exactly one should succeed
        expect(completed.count { |r| r[:success] }).to eq(1)
        expect(completed.count { |r| !r[:success] }).to eq(2)

        # Verify the winner
        expect(winners.size).to eq(1)
        winner = completed.find { |r| r[:success] }
        expect(winner).not_to be_nil
        expect(winner[:error]).to be_nil

        # Verify the losers have proper error messages
        losers = completed.reject { |r| r[:success] }
        losers.each do |loser|
          expect(loser[:error]).to be_present
        end

        # Flow should be completed
        expect(race_flow.reload.completed?).to be true
      end
    end

    context "with cross-user verification attempts" do
      let(:other_user) { Fabricate(:user) }
      let(:user_flow) { create_flow(challenge: "user-challenge", status: "pending", user_id: user.id) }
      let(:other_user_flow) { create_flow(challenge: "other-challenge", status: "pending", user_id: other_user.id) }

      it "prevents user from using another user's flow" do
        # User tries to use other_user's receipt
        other_receipt = generate_jwt({ sub: other_user_flow.challenge }, SiteSetting.humanmark_api_secret)

        result = described_class.call(receipt: other_receipt, context: :post, user: user)

        # Should fail because flow belongs to different user
        expect(result[:success]).to be false
        expect(result[:error]).to be_present

        # Other user's flow should remain pending
        expect(other_user_flow.reload.pending?).to be true
      end

      it "allows anonymous users to use anonymous flows" do
        anon_flow = create_flow(challenge: "anon-challenge", status: "pending", user_id: nil)
        anon_receipt = generate_jwt({ sub: anon_flow.challenge }, SiteSetting.humanmark_api_secret)

        result = described_class.call(receipt: anon_receipt, context: :post, user: nil)

        expect(result[:success]).to be true
        expect(anon_flow.reload.completed?).to be true
      end

      it "prevents logged-in users from using anonymous flows" do
        anon_flow = create_flow(challenge: "anon-challenge", status: "pending", user_id: nil)
        anon_receipt = generate_jwt({ sub: anon_flow.challenge }, SiteSetting.humanmark_api_secret)

        result = described_class.call(receipt: anon_receipt, context: :post, user: user)

        expect(result[:success]).to be false
        expect(result[:error]).to be_present
        expect(anon_flow.reload.pending?).to be true
      end
    end

    context "with tampered flow data" do
      let(:valid_receipt) do
        generate_jwt({ sub: challenge }, SiteSetting.humanmark_api_secret)
      end

      before { flow }

      it "fails when flow status is manually changed to expired" do
        flow.update_column(:status, "expired")

        result = described_class.call(receipt: valid_receipt, context: :post, user: user)

        expect(result[:success]).to be false
        expect(result[:error]).to be_present
        expect(flow.reload.expired?).to be true
      end

      it "fails when flow user_id is tampered" do
        other_user = Fabricate(:user)
        flow.update_column(:user_id, other_user.id)

        result = described_class.call(receipt: valid_receipt, context: :post, user: user)

        expect(result[:success]).to be false
        expect(result[:error]).to be_present
      end

      it "fails when flow context is changed" do
        flow.update_column(:context, "topic")

        # Try to verify with different context
        result = described_class.call(receipt: valid_receipt, context: :post, user: user)

        # Should fail due to context mismatch
        expect(result[:success]).to be false
        expect(result[:error]).to be_present
      end
    end
  end
end
