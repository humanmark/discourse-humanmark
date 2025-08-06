# frozen_string_literal: true

RSpec.describe Jobs::HumanmarkCleanup do
  subject(:job) { described_class.new }

  before do
    SiteSetting.humanmark_enabled = true
    SiteSetting.humanmark_api_key = "test-key"
    SiteSetting.humanmark_api_secret = "test-secret"
    SiteSetting.humanmark_flow_retention_days = 7
    SiteSetting.humanmark_reverify_period_posts = 60
    SiteSetting.humanmark_reverify_period_topics = 0
    SiteSetting.humanmark_reverify_period_messages = 30
  end

  describe "#execute" do
    context "when plugin is disabled" do
      before do
        SiteSetting.humanmark_enabled = false
      end

      it "does not perform cleanup" do
        old_flow = create_flow
        old_flow.update_column(:created_at, 10.days.ago)

        expect { job.execute({}) }.not_to(change { DiscourseHumanmark::Flow.count })
      end
    end

    context "when plugin is enabled" do
      it "marks old pending flows as expired" do
        old_pending = create_flow(status: "pending")
        old_pending.update_column(:created_at, 25.hours.ago)
        recent_pending = create_flow(status: "pending")

        job.execute({})

        expect(old_pending.reload.status).to eq("expired")
        expect(recent_pending.reload.status).to eq("pending")
      end

      it "deletes flows older than retention period" do
        very_old = create_flow(status: "completed")
        very_old.update_column(:created_at, 8.days.ago)

        recent = create_flow(status: "completed")
        recent.update_column(:created_at, 6.days.ago)

        expect { job.execute({}) }.to change { DiscourseHumanmark::Flow.count }.by(-1)
        expect { very_old.reload }.to raise_error(ActiveRecord::RecordNotFound)
        expect(recent.reload).to be_present
      end

      it "respects reverify periods for retention" do
        # Set short retention but long reverify period
        SiteSetting.humanmark_flow_retention_days = 1
        SiteSetting.humanmark_reverify_period_messages = 4320 # 3 days in minutes

        # Flow that's 2 days old (older than retention but within reverify)
        flow = create_flow(status: "completed", context: "message")
        flow.update_column(:created_at, 2.days.ago)

        expect { job.execute({}) }.not_to(change { DiscourseHumanmark::Flow.count })
        expect(flow.reload).to be_present
      end

      it "logs cleanup statistics" do
        # Create flows to be cleaned
        old_pending = create_flow(status: "pending")
        old_pending.update_column(:created_at, 25.hours.ago)

        very_old = create_flow
        very_old.update_column(:created_at, 8.days.ago)

        allow(Rails.logger).to receive(:info)
        job.execute({})
        expect(Rails.logger).to have_received(:info).with(/Cleanup completed/)
      end

      it "handles cleanup errors by logging and re-raising" do
        allow(DiscourseHumanmark::Flow).to receive(:cleanup_old!).and_raise(StandardError, "Test error")
        allow(Rails.logger).to receive(:error)

        # The job logs the error and re-raises it
        expect { job.execute({}) }.to raise_error(StandardError, "Test error")
        expect(Rails.logger).to have_received(:error).with(/Cleanup job failed/)
      end

      context "with mixed flow states" do
        before do
          # Old flows to be deleted
          @old_completed = create_flow(status: "completed")
          @old_completed.update_column(:created_at, 8.days.ago)

          @old_failed = create_flow(status: "failed")
          @old_failed.update_column(:created_at, 8.days.ago)

          @old_expired = create_flow(status: "expired")
          @old_expired.update_column(:created_at, 8.days.ago)

          # Old pending to be marked expired
          @old_pending = create_flow(status: "pending")
          @old_pending.update_column(:created_at, 25.hours.ago)

          # Recent flows to keep
          @recent_pending = create_flow(status: "pending")
          @recent_completed = create_flow(status: "completed")
          @recent_failed = create_flow(status: "failed")
        end

        it "performs all cleanup operations correctly" do
          job.execute({})

          # Old flows should be deleted
          expect { @old_completed.reload }.to raise_error(ActiveRecord::RecordNotFound)
          expect { @old_failed.reload }.to raise_error(ActiveRecord::RecordNotFound)
          expect { @old_expired.reload }.to raise_error(ActiveRecord::RecordNotFound)

          # Old pending should be expired, not deleted
          expect(@old_pending.reload.status).to eq("expired")

          # Recent flows should remain unchanged
          expect(@recent_pending.reload.status).to eq("pending")
          expect(@recent_completed.reload.status).to eq("completed")
          expect(@recent_failed.reload.status).to eq("failed")
        end
      end
    end

    context "with performance considerations" do
      it "uses batch operations for efficiency" do
        # Create many old flows
        100.times do
          flow = create_flow
          flow.update_column(:created_at, 10.days.ago)
        end

        # Should delete all in minimal queries
        expect { job.execute({}) }.to change { DiscourseHumanmark::Flow.count }.by(-100)
      end

      it "uses transaction for consistency" do
        # The cleanup_old! method handles transactions internally
        # Test that it completes successfully
        old_flow = create_flow
        old_flow.update_column(:created_at, 10.days.ago)

        expect { job.execute({}) }.to change { DiscourseHumanmark::Flow.count }.by(-1)
      end
    end
  end

  describe "scheduling" do
    it "is scheduled to run daily" do
      # The job uses 'every 1.day' which schedules it to run daily
      # We can verify this by checking the job is a scheduled job
      expect(described_class.ancestors).to include(Jobs::Scheduled)
    end
  end

  describe "edge cases" do
    it "handles flows with nil timestamps gracefully" do
      flow_with_nil_completed = create_flow(status: "completed")
      flow_with_nil_completed.update_column(:completed_at, nil)
      flow_with_nil_completed.update_column(:created_at, 10.days.ago)

      expect { job.execute({}) }.not_to raise_error
      expect { flow_with_nil_completed.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "handles concurrent cleanup jobs" do
      # Create flows for cleanup
      5.times do
        flow = create_flow
        flow.update_column(:created_at, 10.days.ago)
      end

      # Run two cleanup jobs concurrently
      deleted_count = 0
      threads = 2.times.map do
        Thread.new do
          job.execute({})
          deleted_count += 1
        rescue StandardError
          # One might fail due to flows already being deleted
        end
      end
      threads.each(&:join)

      # Flows should be deleted (by whichever job got there first)
      expect(DiscourseHumanmark::Flow.count).to eq(0)
    end

    it "continues cleanup even if some operations fail" do
      # Create a flow that will cause issues
      problem_flow = create_flow(status: "pending")
      problem_flow.update_column(:created_at, 25.hours.ago)

      # Create a normal old flow
      old_flow = create_flow
      old_flow.update_column(:created_at, 10.days.ago)

      # Mock to simulate partial failure
      allow(problem_flow).to receive(:update!).and_raise(ActiveRecord::RecordInvalid)
      allow(DiscourseHumanmark::Flow).to receive(:find_by).with(id: problem_flow.id).and_return(problem_flow)

      # Should still clean up what it can
      job.execute({})

      # Old flow should still be deleted even if problem_flow caused issues
      expect { old_flow.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "handles flows with invalid status gracefully" do
      invalid_flow = create_flow
      invalid_flow.update_columns(status: "invalid_status", created_at: 10.days.ago)

      expect { job.execute({}) }.not_to raise_error
      # Invalid flow should still be deleted if old enough
      expect { invalid_flow.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "respects minimum retention days setting" do
      SiteSetting.humanmark_flow_retention_days = 1 # Minimum allowed value

      # Flows within retention period should be kept
      recent_flow = create_flow
      recent_flow.update_column(:created_at, 12.hours.ago)

      # Flows outside retention period should be deleted
      old_flow = create_flow
      old_flow.update_column(:created_at, 2.days.ago)

      job.execute({})

      expect(recent_flow.reload).to be_present
      expect { old_flow.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "handles database connection issues gracefully" do
      allow(DiscourseHumanmark::Flow).to receive(:cleanup_old!)
        .and_raise(ActiveRecord::ConnectionNotEstablished, "Database connection lost")

      allow(Rails.logger).to receive(:error)

      expect { job.execute({}) }.to raise_error(ActiveRecord::ConnectionNotEstablished)
      expect(Rails.logger).to have_received(:error).with(/Cleanup job failed/)
    end
  end
end
