# frozen_string_literal: true

RSpec.describe "DiscourseHumanmark::ApiController", :humanmark, type: :request do
  let(:user) { Fabricate(:user) }

  before do
    SiteSetting.humanmark_enabled = true
    SiteSetting.humanmark_api_key = "test-key"
    SiteSetting.humanmark_api_secret = "test-secret"
  end

  describe "POST /humanmark/flows" do
    context "when logged in" do
      before { sign_in(user) }

      context "when verification is required" do
        before do
          SiteSetting.humanmark_protect_posts = true
          stub_humanmark_api_request(success: true)
        end

        it "creates a challenge successfully" do
          post "/humanmark/flows", params: { context: "post" }

          expect(response).to have_http_status(:ok)
          json = JSON.parse(response.body)
          expect(json["required"]).to be true
          expect(json["challenge"]).to be_present
          expect(json["token"]).to be_present
        end

        it "handles API failures" do
          stub_humanmark_api_request(success: false)

          post "/humanmark/flows", params: { context: "post" }
          expect(response).to have_http_status(:unprocessable_entity)
          json = JSON.parse(response.body)
          expect(json["errors"]).to be_present
        end
      end

      context "when verification is not required" do
        before do
          SiteSetting.humanmark_protect_posts = false
        end

        it "returns required: false" do
          post "/humanmark/flows", params: { context: "post" }
          expect(response).to have_http_status(:ok)
          json = JSON.parse(response.body)
          expect(json["required"]).to be false
        end
      end

      context "with rate limiting" do
        before do
          RateLimiter.enable
          SiteSetting.humanmark_protect_posts = true
          SiteSetting.humanmark_max_challenges_per_user_per_minute = 2
          # Set reverify period to 0 to ensure verification is always required
          SiteSetting.humanmark_reverify_period_posts = 0

          # Clear rate limiter cache before tests
          RateLimiter.clear_all_global!

          # Stub API requests to return unique challenges each time
          counter = 0
          stub_request(:post, "https://humanmark.io/api/v1/challenge/create")
            .to_return do |_request|
              counter += 1
              {
                status: 200,
                body: {
                  success: true,
                  challenge: "test-challenge-#{counter}",
                  token: "test-token-#{counter}"
                }.to_json,
                headers: { "Content-Type" => "application/json" }
              }
            end
        end

        after do
          RateLimiter.disable
        end

        it "applies rate limits" do
          # First two requests should succeed
          2.times do |i|
            post "/humanmark/flows", params: { context: "post" }
            expect(response).to have_http_status(:ok), "Request #{i + 1} failed: #{response.body}"
          end

          # Third request should be rate limited
          post "/humanmark/flows", params: { context: "post" }
          expect(response).to have_http_status(:too_many_requests)
        end

        it "allows requests after rate limit window expires" do
          # Hit the rate limit
          2.times do
            post "/humanmark/flows", params: { context: "post" }
            expect(response).to have_http_status(:ok)
          end

          # Should be rate limited
          post "/humanmark/flows", params: { context: "post" }
          expect(response).to have_http_status(:too_many_requests)

          # Travel forward in time past the rate limit window
          freeze_time 2.minutes.from_now do
            # Clear rate limiter cache after time travel
            RateLimiter.clear_all_global!

            # Should be able to make requests again
            post "/humanmark/flows", params: { context: "post" }
            expect(response).to have_http_status(:ok)

            # Can make another request
            post "/humanmark/flows", params: { context: "post" }
            expect(response).to have_http_status(:ok)

            # But third request in new window is limited
            post "/humanmark/flows", params: { context: "post" }
            expect(response).to have_http_status(:too_many_requests)
          end
        end

        it "tracks rate limits per user independently" do
          other_user = Fabricate(:user)

          # User 1 hits their limit
          sign_in(user)
          2.times do
            post "/humanmark/flows", params: { context: "post" }
            expect(response).to have_http_status(:ok)
          end
          post "/humanmark/flows", params: { context: "post" }
          expect(response).to have_http_status(:too_many_requests)

          # User 2 can still make requests
          sign_in(other_user)
          2.times do |i|
            post "/humanmark/flows", params: { context: "post" }
            expect(response).to have_http_status(:ok), "User 2 request #{i + 1} failed"
          end
          # User 2 hits their limit
          post "/humanmark/flows", params: { context: "post" }
          expect(response).to have_http_status(:too_many_requests)
        end
      end
    end

    context "when anonymous" do
      context "when verification is required" do
        before do
          SiteSetting.humanmark_protect_posts = true
          stub_humanmark_api_request(success: true)
        end

        it "creates a challenge for anonymous users" do
          post "/humanmark/flows", params: { context: "post" }
          expect(response).to have_http_status(:ok)
          json = JSON.parse(response.body)
          expect(json["required"]).to be true
          expect(json["challenge"]).to be_present

          flow = DiscourseHumanmark::Flow.last
          expect(flow.user_id).to be_nil
        end
      end

      context "when verification is not required" do
        before do
          SiteSetting.humanmark_protect_posts = false
        end

        it "returns required: false for anonymous users" do
          post "/humanmark/flows", params: { context: "post" }
          expect(response).to have_http_status(:ok)
          json = JSON.parse(response.body)
          expect(json["required"]).to be false
        end
      end
    end

    context "with invalid params" do
      before { sign_in(user) }

      it "handles invalid context" do
        post "/humanmark/flows", params: { context: "invalid" }
        expect(response).to have_http_status(:bad_request) # Bad request for invalid context
        json = JSON.parse(response.body)
        expect(json["errors"]).to be_present
      end

      it "handles missing context" do
        post "/humanmark/flows", params: {}
        expect(response).to have_http_status(:bad_request) # Bad request for missing required param
        json = JSON.parse(response.body)
        expect(json["errors"]).to be_present
      end
    end
  end
end
