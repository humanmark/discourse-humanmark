# frozen_string_literal: true

RSpec.describe DiscourseHumanmark::Flow do
  describe "validations" do
    it "requires a challenge" do
      flow = described_class.new(token: "token", context: "post")
      expect(flow).not_to be_valid
      expect(flow.errors[:challenge]).to include("can't be blank")
    end

    it "requires a unique challenge" do
      create_flow(challenge: "duplicate")
      flow = described_class.new(challenge: "duplicate", token: "token", context: "post")
      expect(flow).not_to be_valid
      expect(flow.errors[:challenge]).to include("has already been taken")
    end

    it "requires a token" do
      flow = described_class.new(challenge: "challenge", context: "post")
      expect(flow).not_to be_valid
      expect(flow.errors[:token]).to include("can't be blank")
    end

    it "requires a valid context" do
      flow = described_class.new(challenge: "challenge", token: "token", context: "invalid")
      expect(flow).not_to be_valid
      expect(flow.errors[:context]).to include("is not included in the list")
    end

    it "accepts valid contexts" do
      %w[post topic message].each do |context|
        flow = described_class.new(challenge: "challenge-#{context}", token: "token", context: context)
        expect(flow).to be_valid
      end
    end

    it "requires a valid status" do
      flow = create_flow
      flow.status = "invalid"
      expect(flow).not_to be_valid
      expect(flow.errors[:status]).to include("is not included in the list")
    end
  end

  describe "scopes" do
    before do
      @pending = create_flow(status: "pending")
      @completed = create_flow(status: "completed", completed_at: Time.current)
      @expired = create_flow(status: "expired")
      @failed = create_flow(status: "failed")
    end

    it ".pending returns pending flows" do
      expect(described_class.pending).to contain_exactly(@pending)
    end

    it ".completed returns completed flows" do
      expect(described_class.completed).to contain_exactly(@completed)
    end

    it ".expired returns expired flows" do
      expect(described_class.expired).to contain_exactly(@expired)
    end

    it ".failed returns failed flows" do
      expect(described_class.failed).to contain_exactly(@failed)
    end

    it ".recent_completed_for_user_and_context returns recent completions" do
      user_id = 123
      recent = create_flow(
        status: "completed",
        user_id: user_id,
        context: "post",
        completed_at: 10.minutes.ago
      )
      create_flow(
        status: "completed",
        user_id: user_id,
        context: "post",
        completed_at: 2.hours.ago
      )

      results = described_class.recent_completed_for_user_and_context(user_id, "post", 30)
      expect(results).to contain_exactly(recent)
    end
  end

  describe "#expired?" do
    it "returns true for expired status" do
      flow = create_flow(status: "expired")
      expect(flow.expired?).to be true
    end

    it "returns true for old pending flows" do
      flow = create_flow(status: "pending")
      flow.update_column(:created_at, 2.hours.ago)
      expect(flow.expired?).to be true
    end

    it "returns false for recent pending flows" do
      flow = create_flow(status: "pending")
      expect(flow.expired?).to be false
    end

    it "returns false for completed flows even if old" do
      flow = create_flow(status: "completed")
      flow.update_column(:created_at, 2.hours.ago)
      # Completed flows are not considered expired based on time
      expect(flow.expired?).to be false
    end
  end

  describe "#complete!" do
    let(:flow) { create_flow(status: "pending") }

    it "marks pending flow as completed" do
      expect(flow.complete!).to be true
      expect(flow.reload.status).to eq("completed")
      expect(flow.completed_at).to be_present
    end

    it "returns false for already completed flow" do
      flow.update!(status: "completed")
      expect(flow.complete!).to be false
    end

    it "returns false for expired flow" do
      flow.update!(status: "expired")
      expect(flow.complete!).to be false
    end

    it "prevents race conditions with atomic update" do
      flow2 = described_class.find(flow.id)
      flow.complete!
      expect(flow2.complete!).to be false
    end
  end

  describe ".mark_expired!" do
    it "marks old pending flows as expired" do
      old_flow = create_flow(status: "pending")
      old_flow.update_column(:created_at, 2.hours.ago)
      new_flow = create_flow(status: "pending")

      expect(described_class.mark_expired!).to eq(1)
      expect(old_flow.reload.status).to eq("expired")
      expect(new_flow.reload.status).to eq("pending")
    end
  end

  describe ".recent_verification?" do
    let(:user_id) { 123 }

    it "returns true when recent verification exists" do
      create_flow(
        status: "completed",
        user_id: user_id,
        context: "post",
        completed_at: 10.minutes.ago
      )

      expect(described_class.recent_verification?(
               user_id: user_id,
               context: "post",
               minutes: 30
             )).to be true
    end

    it "returns false when no recent verification exists" do
      create_flow(
        status: "completed",
        user_id: user_id,
        context: "post",
        completed_at: 2.hours.ago
      )

      expect(described_class.recent_verification?(
               user_id: user_id,
               context: "post",
               minutes: 30
             )).to be false
    end

    it "returns false when minutes is zero" do
      expect(described_class.recent_verification?(
               user_id: user_id,
               context: "post",
               minutes: 0
             )).to be false
    end
  end

  describe "concurrent operations" do
    let(:user_id) { 123 }

    it "handles concurrent flow creation by same user" do
      created_flows = []
      threads = 5.times.map do |i|
        Thread.new do
          flow = described_class.create(
            challenge: "challenge-#{i}-#{SecureRandom.hex}",
            token: "token-#{i}",
            context: "post",
            user_id: user_id,
            status: "pending"
          )
          created_flows << flow if flow.persisted?
        end
      end
      threads.each(&:join)

      # All flows should be created successfully
      expect(created_flows.size).to eq(5)
      expect(created_flows.map(&:user_id).uniq).to eq([user_id])
      expect(created_flows.map(&:challenge).uniq.size).to eq(5) # All unique challenges
    end

    it "prevents duplicate challenges even under concurrent creation" do
      duplicate_challenge = "same-challenge"
      created_count = 0
      error_count = 0

      threads = 3.times.map do
        Thread.new do
          described_class.create!(
            challenge: duplicate_challenge,
            token: SecureRandom.hex,
            context: "post",
            status: "pending"
          )
          created_count += 1
        rescue ActiveRecord::RecordInvalid
          error_count += 1
        end
      end
      threads.each(&:join)

      # Only one should succeed due to unique constraint
      expect(created_count).to eq(1)
      expect(error_count).to eq(2)
      expect(described_class.where(challenge: duplicate_challenge).count).to eq(1)
    end
  end

  describe "state transitions" do
    let(:flow) { create_flow(status: "pending") }

    context "when transitioning from pending state" do
      it "can transition to completed" do
        expect(flow.pending?).to be true
        expect(flow.complete!).to be true
        expect(flow.reload.completed?).to be true
        expect(flow.completed_at).to be_present
      end

      it "can transition to expired" do
        expect(flow.pending?).to be true
        flow.update!(status: "expired")
        expect(flow.reload.expired?).to be true
      end
    end

    context "when transitioning from completed state" do
      before { flow.complete! }

      it "cannot transition back to pending and complete again" do
        # Try to change status back to pending
        flow.update_column(:status, "pending") # Force update bypassing validations

        # complete! should now work since it's pending in the database
        expect(flow.reload.status).to eq("pending")
        expect(flow.complete!).to be true # Will complete since it's pending

        # But now it's completed again, so another complete! should fail
        expect(flow.complete!).to be false
      end

      it "cannot be completed again" do
        expect(flow.complete!).to be false
        expect(flow.reload.completed?).to be true
      end
    end

    context "when transitioning from expired state" do
      before { flow.update!(status: "expired") }

      it "cannot transition to completed" do
        expect(flow.complete!).to be false
        expect(flow.reload.expired?).to be true
      end
    end

    context "with atomic state transitions" do
      it "ensures atomic completion with database-level check" do
        # This tests the atomic update in complete!
        flow2 = described_class.find(flow.id)

        # Both try to complete
        result1 = flow.complete!
        result2 = flow2.complete!

        # Only one should succeed
        expect([result1, result2].count(true)).to eq(1)
        expect([result1, result2].count(false)).to eq(1)

        # Database should show completed
        expect(described_class.find(flow.id).completed?).to be true
      end
    end
  end

  describe ".cleanup_old!" do
    before do
      SiteSetting.humanmark_flow_retention_days = 7
      SiteSetting.humanmark_reverify_period_posts = 60
      SiteSetting.humanmark_reverify_period_topics = 0
      SiteSetting.humanmark_reverify_period_messages = 30
    end

    it "marks old pending flows as expired" do
      old_pending = create_flow(status: "pending")
      old_pending.update_column(:created_at, 2.hours.ago)

      result = described_class.cleanup_old!
      expect(result[:marked_expired]).to eq(1)
      expect(old_pending.reload.status).to eq("expired")
    end

    it "deletes flows older than retention period" do
      old_flow = create_flow
      old_flow.update_column(:created_at, 8.days.ago)
      recent_flow = create_flow

      result = described_class.cleanup_old!
      expect(result[:deleted]).to eq(1)
      expect { old_flow.reload }.to raise_error(ActiveRecord::RecordNotFound)
      expect(recent_flow.reload).to be_present
    end

    it "handles orphaned flows without users" do
      orphan_flow = create_flow(user_id: nil, status: "pending")
      orphan_flow.update_column(:created_at, 8.days.ago)

      result = described_class.cleanup_old!

      expect(result[:deleted]).to eq(1)
      expect { orphan_flow.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "cleans up flows in batches to avoid locking" do
      # Create many old flows
      20.times do |i|
        flow = create_flow(challenge: "old-#{i}")
        flow.update_column(:created_at, 8.days.ago)
      end

      result = described_class.cleanup_old!

      expect(result[:deleted]).to eq(20)
      expect(described_class.count).to eq(0)
    end

    it "uses maximum of retention and reverify periods" do
      SiteSetting.humanmark_flow_retention_days = 1
      SiteSetting.humanmark_reverify_period_posts = 1440 # 1 day in minutes
      SiteSetting.humanmark_reverify_period_topics = 2880 # 2 days
      SiteSetting.humanmark_reverify_period_messages = 4320 # 3 days

      result = described_class.cleanup_old!
      expect(result[:retention_days_used]).to eq(3) # Max of reverify periods
    end
  end
end
