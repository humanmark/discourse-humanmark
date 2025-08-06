# frozen_string_literal: true

RSpec.describe DiscourseHumanmark::ChallengeService, :humanmark, type: :service do
  let(:api_url) { "#{SiteSetting.humanmark_api_url}/api/v1/challenge/create" }

  before do
    SiteSetting.humanmark_enabled = true
    SiteSetting.humanmark_api_key = "test-key"
    SiteSetting.humanmark_api_secret = "test-secret"
  end

  describe "#call" do
    context "with valid API response" do
      before do
        stub_request(:post, api_url)
          .with(
            headers: {
              "hm-api-key" => "test-key",
              "hm-api-secret" => "test-secret",
              "Content-Type" => "application/json"
            },
            body: hash_including("domain")
          )
          .to_return(
            status: 200,
            body: {
              success: true,
              challenge: "test-challenge",
              token: "test-token"
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns success with challenge data" do
        result = described_class.call
        expect(result[:success]).to be true
        expect(result[:challenge]).to eq("test-challenge")
        expect(result[:token]).to eq("test-token")
      end

      it "includes configured domain in request" do
        SiteSetting.humanmark_domain = "forum.example.com"

        stub_request(:post, api_url)
          .with(
            body: hash_including("domain" => "forum.example.com")
          )
          .to_return(mock_humanmark_api_response(success: true))

        result = described_class.call
        expect(result[:success]).to be true
      end
    end

    context "with API errors" do
      it "handles authentication errors" do
        stub_request(:post, api_url)
          .to_return(
            status: 401,
            body: { error: "Unauthorized" }.to_json
          )

        result = described_class.call
        expect(result[:success]).to be false
        expect(result[:error]).to be_present
      end

      it "handles rate limiting" do
        stub_request(:post, api_url)
          .to_return(
            status: 429,
            body: { error: "Rate limited" }.to_json
          )

        result = described_class.call
        expect(result[:success]).to be false
        expect(result[:error]).to be_present
      end

      it "handles timeout errors" do
        stub_request(:post, api_url).to_timeout

        result = described_class.call
        expect(result[:success]).to be false
        expect(result[:error]).to be_present
      end

      it "handles network errors" do
        stub_request(:post, api_url).to_raise(Errno::ECONNREFUSED)

        result = described_class.call
        expect(result[:success]).to be false
        expect(result[:error]).to be_present
      end
    end

    context "with missing configuration" do
      it "fails when API key is missing" do
        SiteSetting.humanmark_api_key = ""

        result = described_class.call
        expect(result[:success]).to be false
        expect(result[:error]).to be_present
      end

      it "fails when API secret is missing" do
        SiteSetting.humanmark_api_secret = ""

        result = described_class.call
        expect(result[:success]).to be false
        expect(result[:error]).to be_present
      end
    end
  end
end
