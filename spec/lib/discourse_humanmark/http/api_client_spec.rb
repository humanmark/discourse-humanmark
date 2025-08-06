# frozen_string_literal: true

RSpec.describe DiscourseHumanmark::Http::ApiClient do
  let(:api_key) { "test-api-key" }
  let(:api_secret) { "test-api-secret" }
  let(:api_url) { "https://humanmark.io" }
  let(:endpoint) { "/api/v1/challenge/create" }
  let(:payload) { { domain: "example.com" } }

  before do
    SiteSetting.humanmark_api_key = api_key
    SiteSetting.humanmark_api_secret = api_secret
    SiteSetting.humanmark_api_url = api_url
    # Reset connection pool before each test to ensure clean state
    described_class.reset_connection_pool!
  end

  describe ".post" do
    context "with successful response" do
      before do
        stub_request(:post, "#{api_url}#{endpoint}")
          .with(
            body: payload.to_json,
            headers: {
              "Content-Type" => "application/json",
              "hm-api-key" => api_key,
              "hm-api-secret" => api_secret
            }
          )
          .to_return(
            status: 200,
            body: { success: true, challenge: "test-challenge" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "makes POST request with correct headers" do
        response = described_class.post(endpoint, payload)

        expect(response[:success]).to be true
        # Data is wrapped in a :data key by ResponseHandler
        expect(response[:data]).to be_a(Hash)
        expect(response[:data]["success"]).to be true
        expect(response[:data]["challenge"]).to eq("test-challenge")
        expect(response[:data]["challenge"]).to be_a(String)
        expect(response[:data].keys).to include("success", "challenge")
      end

      it "includes debug logging when enabled" do
        SiteSetting.humanmark_debug_mode = true
        allow(Rails.logger).to receive(:debug)

        described_class.post(endpoint, payload)

        expect(Rails.logger).to have_received(:debug).with(/\[Humanmark\] API request: method=POST/)
        expect(Rails.logger).to have_received(:debug).with("[Humanmark] API success")
      end
    end

    context "with connection failures" do
      it "handles connection timeout" do
        stub_request(:post, "#{api_url}#{endpoint}")
          .to_timeout

        response = described_class.post(endpoint, payload)

        expect(response[:success]).to be false
        expect(response[:error]).to eq(I18n.t("humanmark.api_timeout"))
      end

      it "handles network errors" do
        # Excon::Error::Socket doesn't take a string, it takes an exception
        error = StandardError.new("Connection refused")
        stub_request(:post, "#{api_url}#{endpoint}")
          .to_raise(Excon::Error::Socket.new(error))

        response = described_class.post(endpoint, payload)

        expect(response[:success]).to be false
        expect(response[:error]).to eq(I18n.t("humanmark.api_error"))
      end

      it "handles generic Excon errors" do
        stub_request(:post, "#{api_url}#{endpoint}")
          .to_raise(Excon::Error.new("Generic connection error"))

        response = described_class.post(endpoint, payload)

        expect(response[:success]).to be false
        expect(response[:error]).to eq(I18n.t("humanmark.api_error"))
      end
    end

    context "with invalid URLs" do
      it "rejects non-HTTPS URLs" do
        SiteSetting.humanmark_api_url = "http://humanmark.io"

        expect do
          described_class.post(endpoint, payload)
        end.to raise_error(RuntimeError, /Invalid URL/)
      end

      it "rejects invalid URL format" do
        SiteSetting.humanmark_api_url = "not-a-url"

        expect do
          described_class.post(endpoint, payload)
        end.to raise_error(RuntimeError, /Invalid URL/)
      end

      it "rejects URLs with invalid protocols" do
        SiteSetting.humanmark_api_url = "ftp://humanmark.io"

        expect do
          described_class.post(endpoint, payload)
        end.to raise_error(RuntimeError, /Invalid URL/)
      end
    end

    context "with different status codes" do
      it "handles 400 bad request" do
        stub_request(:post, "#{api_url}#{endpoint}")
          .to_return(
            status: 400,
            body: { error: "Invalid request" }.to_json
          )

        response = described_class.post(endpoint, payload)

        expect(response[:success]).to be false
        expect(response[:error]).to eq("Invalid request")
      end

      it "handles 401 unauthorized" do
        stub_request(:post, "#{api_url}#{endpoint}")
          .to_return(
            status: 401,
            body: { error: "Invalid credentials" }.to_json
          )

        response = described_class.post(endpoint, payload)

        expect(response[:success]).to be false
        expect(response[:error]).to eq(I18n.t("humanmark.unauthorized"))
      end

      it "handles 429 rate limited" do
        stub_request(:post, "#{api_url}#{endpoint}")
          .to_return(
            status: 429,
            body: { error: "Rate limited" }.to_json
          )

        response = described_class.post(endpoint, payload)

        expect(response[:success]).to be false
        expect(response[:error]).to eq(I18n.t("humanmark.rate_limited"))
      end

      it "handles 500 server error" do
        stub_request(:post, "#{api_url}#{endpoint}")
          .to_return(
            status: 500,
            body: { error: "Internal server error" }.to_json
          )

        response = described_class.post(endpoint, payload)

        expect(response[:success]).to be false
        expect(response[:error]).to eq(I18n.t("humanmark.server_error"))
      end
    end

    context "with response parsing" do
      it "handles malformed JSON response" do
        stub_request(:post, "#{api_url}#{endpoint}")
          .to_return(
            status: 200,
            body: "not-json",
            headers: { "Content-Type" => "application/json" }
          )

        allow(Rails.logger).to receive(:error)

        response = described_class.post(endpoint, payload)

        # Should return error for invalid JSON even with 200 status
        expect(response[:success]).to be false
        expect(response[:error]).to eq(I18n.t("humanmark.invalid_response"))
        expect(Rails.logger).to have_received(:error).with(/Invalid JSON response/)
      end

      it "handles empty response body" do
        stub_request(:post, "#{api_url}#{endpoint}")
          .to_return(
            status: 200,
            body: "",
            headers: { "Content-Type" => "application/json" }
          )

        response = described_class.post(endpoint, payload)

        # Empty body parses as empty hash, which is still success
        expect(response[:success]).to be true
        expect(response[:data]).to eq({})
      end

      it "handles HTML error pages" do
        stub_request(:post, "#{api_url}#{endpoint}")
          .to_return(
            status: 502,
            body: "<html><body>502 Bad Gateway</body></html>",
            headers: { "Content-Type" => "text/html" }
          )

        response = described_class.post(endpoint, payload)

        expect(response[:success]).to be false
        expect(response[:error]).to eq(I18n.t("humanmark.server_error"))
      end
    end
  end

  describe "configuration" do
    it "uses SiteSetting for api_key" do
      SiteSetting.humanmark_api_key = "custom-key"

      stub_request(:post, "#{api_url}#{endpoint}")
        .with(headers: { "hm-api-key" => "custom-key" })
        .to_return(status: 200, body: { success: true }.to_json)

      response = described_class.post(endpoint, {})
      expect(response[:success]).to be true
    end

    it "uses SiteSetting for api_secret" do
      SiteSetting.humanmark_api_secret = "custom-secret"

      stub_request(:post, "#{api_url}#{endpoint}")
        .with(headers: { "hm-api-secret" => "custom-secret" })
        .to_return(status: 200, body: { success: true }.to_json)

      response = described_class.post(endpoint, {})
      expect(response[:success]).to be true
    end

    it "uses SiteSetting for api_url" do
      custom_url = "https://custom.humanmark.io"
      SiteSetting.humanmark_api_url = custom_url

      stub_request(:post, "#{custom_url}#{endpoint}")
        .to_return(status: 200, body: { success: true }.to_json)

      response = described_class.post(endpoint, {})
      expect(response[:success]).to be true
    end
  end

  describe "timeout configuration" do
    it "handles timeout gracefully" do
      stub_request(:post, "#{api_url}#{endpoint}")
        .to_timeout

      response = described_class.post(endpoint, {})

      expect(response[:success]).to be false
      expect(response[:error]).to eq(I18n.t("humanmark.api_timeout"))
    end
  end
end
