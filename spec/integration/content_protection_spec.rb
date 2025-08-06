# frozen_string_literal: true

RSpec.describe "Content Protection Integration", :humanmark, type: :integration do
  # NOTE: The event handlers are registered at plugin load time based on settings.
  # In production, settings are configured before the plugin loads.
  # In tests, we can't dynamically re-register event handlers, so we test
  # the services and API directly rather than the event integration.

  let(:user) { Fabricate(:user, trust_level: 1) }
  let(:category) { Fabricate(:category) }
  let(:topic) { Fabricate(:topic, category: category) }

  before do
    SiteSetting.humanmark_enabled = true
    SiteSetting.humanmark_api_key = "test-key"
    SiteSetting.humanmark_api_secret = "test-secret"
  end

  describe "Verification Service" do
    let(:valid_receipt) { generate_jwt({ sub: "test-challenge" }, SiteSetting.humanmark_api_secret) }

    before do
      create_flow(challenge: "test-challenge", status: "pending", user_id: user.id)
    end

    context "when protection is enabled" do
      before do
        SiteSetting.humanmark_protect_posts = true
      end

      it "requires verification when protection enabled" do
        result = DiscourseHumanmark::VerificationService.call(
          context: :post,
          user: user,
          receipt: nil
        )

        expect(result[:success]).to be false
        expect(result[:error]).to be_present
      end

      it "allows with valid verification" do
        result = DiscourseHumanmark::VerificationService.call(
          context: :post,
          user: user,
          receipt: valid_receipt
        )

        expect(result[:success]).to be true
        expect(result[:verified]).to be true
      end

      context "with bypass rules" do
        it "bypasses for staff" do
          SiteSetting.humanmark_bypass_staff = true
          admin = Fabricate(:admin)

          result = DiscourseHumanmark::VerificationService.call(
            context: :post,
            user: admin,
            receipt: nil
          )

          expect(result[:success]).to be true
          expect(result[:required]).to be false
        end

        it "bypasses for high trust users" do
          SiteSetting.humanmark_bypass_trust_level = 2
          trusted_user = Fabricate(:user, trust_level: 3)

          result = DiscourseHumanmark::VerificationService.call(
            context: :post,
            user: trusted_user,
            receipt: nil
          )

          expect(result[:success]).to be true
          expect(result[:required]).to be false
        end

        it "requires verification when bypass level is 5" do
          SiteSetting.humanmark_bypass_trust_level = 5
          high_trust_user = Fabricate(:user, trust_level: 4)

          result = DiscourseHumanmark::VerificationService.call(
            context: :post,
            user: high_trust_user,
            receipt: nil
          )

          expect(result[:success]).to be false
          expect(result[:error]).to be_present
        end
      end

      context "with reverify periods" do
        before do
          SiteSetting.humanmark_reverify_period_posts = 30
        end

        it "skips verification within reverify period" do
          # Complete a verification
          flow = DiscourseHumanmark::Flow.find_by(challenge: "test-challenge")
          flow.complete!

          # Should not require verification for next post
          result = DiscourseHumanmark::VerificationService.call(
            context: :post,
            user: user,
            receipt: nil
          )

          expect(result[:success]).to be true
          expect(result[:required]).to be false
        end

        it "requires verification after reverify period" do
          # Complete a verification but make it old
          flow = DiscourseHumanmark::Flow.find_by(challenge: "test-challenge")
          flow.complete!
          flow.update_column(:completed_at, 45.minutes.ago)

          # Should require verification
          result = DiscourseHumanmark::VerificationService.call(
            context: :post,
            user: user,
            receipt: nil
          )

          expect(result[:success]).to be false
          expect(result[:error]).to be_present
        end
      end
    end

    context "with different contexts" do
      let(:topic_challenge) { "topic-challenge-123" }
      let(:topic_receipt) { generate_jwt({ sub: topic_challenge }, SiteSetting.humanmark_api_secret) }

      before do
        SiteSetting.humanmark_protect_topics = true
        create_flow(challenge: topic_challenge, status: "pending", user_id: user.id, context: "topic")
      end

      it "requires verification for topics" do
        result = DiscourseHumanmark::VerificationService.call(
          context: :topic,
          user: user,
          receipt: nil
        )

        expect(result[:success]).to be false
        expect(result[:error]).to be_present
      end

      it "allows topic creation with verification" do
        result = DiscourseHumanmark::VerificationService.call(
          context: :topic,
          user: user,
          receipt: topic_receipt
        )

        expect(result[:success]).to be true
        expect(result[:verified]).to be true
      end
    end

    context "with private messages" do
      let(:message_challenge) { "message-challenge-123" }
      let(:message_receipt) { generate_jwt({ sub: message_challenge }, SiteSetting.humanmark_api_secret) }

      before do
        SiteSetting.humanmark_protect_messages = true
        create_flow(challenge: message_challenge, status: "pending", user_id: user.id, context: "message")
      end

      it "requires verification for messages" do
        result = DiscourseHumanmark::VerificationService.call(
          context: :message,
          user: user,
          receipt: nil
        )

        expect(result[:success]).to be false
        expect(result[:error]).to be_present
      end

      it "allows PM creation with verification" do
        result = DiscourseHumanmark::VerificationService.call(
          context: :message,
          user: user,
          receipt: message_receipt
        )

        expect(result[:success]).to be true
        expect(result[:verified]).to be true
      end
    end

    context "with multiple contexts" do
      before do
        SiteSetting.humanmark_protect_posts = true
        SiteSetting.humanmark_protect_topics = true
        SiteSetting.humanmark_reverify_period_posts = 30
        SiteSetting.humanmark_reverify_period_topics = 0
      end

      it "tracks verification separately per context" do
        # Complete verification for posts
        create_flow(
          challenge: "post-challenge",
          context: "post",
          user_id: user.id,
          status: "completed",
          completed_at: 5.minutes.ago
        )

        # Post verification should not require new verification (within reverify period)
        post_result = DiscourseHumanmark::VerificationService.call(
          context: :post,
          user: user,
          receipt: nil
        )
        expect(post_result[:success]).to be true
        expect(post_result[:required]).to be false

        # Topic verification should still require verification (reverify_period = 0)
        topic_result = DiscourseHumanmark::VerificationService.call(
          context: :topic,
          user: user,
          receipt: nil
        )
        expect(topic_result[:success]).to be false
        expect(topic_result[:error]).to be_present
      end
    end
  end

  describe "Complete Verification Flow" do
    before do
      SiteSetting.humanmark_protect_posts = true
      SiteSetting.humanmark_reverify_period_posts = 0 # Always require verification
      stub_humanmark_api_request(success: true)
    end

    it "completes full verification flow from challenge to completion" do
      # Step 1: Create a flow
      flow_result = DiscourseHumanmark::FlowService.call(
        action: :create,
        context: :post,
        user: user
      )

      expect(flow_result[:success]).to be true
      flow = flow_result[:flow]
      expect(flow).to be_present
      expect(flow.pending?).to be true
      expect(flow.user_id).to eq(user.id)

      # Step 2: Generate a receipt (simulating SDK completion)
      receipt = generate_jwt({ sub: flow.challenge }, SiteSetting.humanmark_api_secret)

      # Step 3: Verify the receipt
      receipt_result = DiscourseHumanmark::ReceiptService.call(
        receipt: receipt,
        context: :post
      )

      expect(receipt_result[:success]).to be true
      expect(receipt_result[:challenge]).to eq(flow.challenge)

      # Step 4: Complete the flow
      complete_result = DiscourseHumanmark::FlowService.call(
        action: :complete,
        challenge: flow.challenge,
        user: user,
        context: :post
      )

      expect(complete_result[:success]).to be true

      # Step 5: Verify final state
      flow.reload
      expect(flow.completed?).to be true
      expect(flow.completed_at).to be_present

      # Step 6: Try to reuse the same receipt (should fail)
      verification_result = DiscourseHumanmark::VerificationService.call(
        receipt: receipt,
        context: :post,
        user: user
      )

      # Should fail because flow is already completed (prevents reuse)
      expect(verification_result[:success]).to be false
      expect(verification_result[:error]).to eq(I18n.t("humanmark.challenge_already_used"))
    end

    it "handles multi-user concurrent verification for same context" do
      # Don't stub again - already stubbed in before block

      users = 3.times.map { Fabricate(:user) }
      flows = []
      receipts = []

      # Each user creates a flow
      users.each_with_index do |u, i|
        flow_result = DiscourseHumanmark::FlowService.call(
          action: :create,
          context: :post,
          user: u
        )
        expect(flow_result[:success]).to(be(true), "Failed to create flow for user #{i}: #{flow_result[:error]}")
        flows << flow_result[:flow]
        receipts << generate_jwt({ sub: flow_result[:flow].challenge }, SiteSetting.humanmark_api_secret)
      end

      # All users verify concurrently
      results = []
      threads = users.each_with_index.map do |u, i|
        Thread.new do
          result = DiscourseHumanmark::FlowService.call(
            action: :complete,
            challenge: flows[i].challenge,
            user: u,
            context: :post
          )
          results << result
        end
      end
      threads.each(&:join)

      # All should succeed with their own flows
      expect(results.all? { |r| r[:success] }).to be true

      # Each flow should be completed
      flows.each(&:reload)
      expect(flows.all?(&:completed?)).to be true

      # Each user completed their own flow
      flows.each_with_index do |flow, i|
        expect(flow.user_id).to eq(users[i].id)
      end
    end

    it "verifies staff bypass works in complete flow" do
      SiteSetting.humanmark_bypass_staff = true
      admin = Fabricate(:admin)

      # Admin shouldn't need verification
      is_required = DiscourseHumanmark::Verification::VerificationRequirements.verification_required?(
        user: admin,
        context: :post
      )

      expect(is_required).to be false

      # Verification service should allow without receipt
      result = DiscourseHumanmark::VerificationService.call(
        context: :post,
        user: admin,
        receipt: nil
      )

      expect(result[:success]).to be true
      expect(result[:required]).to be false
      expect(result[:verified]).to be true
    end

    it "verifies trust level bypass works correctly" do
      SiteSetting.humanmark_bypass_trust_level = 2

      # User below threshold needs verification
      low_trust_user = Fabricate(:user, trust_level: 1)
      low_required = DiscourseHumanmark::Verification::VerificationRequirements.verification_required?(
        user: low_trust_user,
        context: :post
      )
      expect(low_required).to be true

      # User at threshold is bypassed
      mid_trust_user = Fabricate(:user, trust_level: 2)
      mid_required = DiscourseHumanmark::Verification::VerificationRequirements.verification_required?(
        user: mid_trust_user,
        context: :post
      )
      expect(mid_required).to be false

      # User above threshold is also bypassed
      high_trust_user = Fabricate(:user, trust_level: 3)
      high_required = DiscourseHumanmark::Verification::VerificationRequirements.verification_required?(
        user: high_trust_user,
        context: :post
      )
      expect(high_required).to be false
    end

    it "handles anonymous user verification flow" do
      # Anonymous user creates a flow
      flow_result = DiscourseHumanmark::FlowService.call(
        action: :create,
        context: :post,
        user: nil
      )

      expect(flow_result[:success]).to be true
      flow = flow_result[:flow]
      expect(flow.user_id).to be_nil

      # Generate receipt
      receipt = generate_jwt({ sub: flow.challenge }, SiteSetting.humanmark_api_secret)

      # Anonymous user verifies
      verification_result = DiscourseHumanmark::VerificationService.call(
        receipt: receipt,
        context: :post,
        user: nil
      )

      expect(verification_result[:success]).to be true
      expect(verification_result[:verified]).to be true

      # Flow should be completed
      expect(flow.reload.completed?).to be true
    end

    it "prevents cross-context verification" do
      # Create flow for posts
      post_flow_result = DiscourseHumanmark::FlowService.call(
        action: :create,
        context: :post,
        user: user
      )
      post_flow = post_flow_result[:flow]
      post_receipt = generate_jwt({ sub: post_flow.challenge }, SiteSetting.humanmark_api_secret)

      # Try to use post receipt for topic creation
      SiteSetting.humanmark_protect_topics = true

      topic_verification = DiscourseHumanmark::VerificationService.call(
        receipt: post_receipt,
        context: :topic,
        user: user
      )

      # Should fail due to context mismatch
      expect(topic_verification[:success]).to be false
      expect(topic_verification[:error]).to be_present

      # Original flow should still be pending
      expect(post_flow.reload.pending?).to be true
    end
  end
end
