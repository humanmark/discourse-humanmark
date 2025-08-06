# frozen_string_literal: true

# rubocop:disable RSpec/VerifiedDoubles
# We're mocking Excon response objects which are external to our codebase
RSpec.describe DiscourseHumanmark::Http::ResponseHandler do
  let(:json_headers) { { "Content-Type" => "application/json" } }

  describe ".handle" do
    context "with successful responses" do
      it "handles 200 OK" do
        response = double(
          status: 200,
          body: { success: true, data: "test" }.to_json,
          headers: json_headers
        )

        result = described_class.handle(response)

        expect(result[:success]).to be true
        expect(result[:data]).to eq({ "success" => true, "data" => "test" })
      end

      it "handles 201 Created" do
        response = double(
          status: 201,
          body: { created: true, id: 123 }.to_json,
          headers: json_headers
        )

        result = described_class.handle(response)

        expect(result[:success]).to be true
        expect(result[:data]).to eq({ "created" => true, "id" => 123 })
      end

      it "logs debug message when debug mode enabled" do
        SiteSetting.humanmark_debug_mode = true
        response = double(status: 200, body: "{}".to_json, headers: json_headers)

        allow(Rails.logger).to receive(:debug)

        described_class.handle(response)

        expect(Rails.logger).to have_received(:debug).with("[Humanmark] API success")
      end

      it "handles empty JSON body" do
        response = double(status: 200, body: "{}", headers: json_headers)

        result = described_class.handle(response)

        expect(result[:success]).to be true
        expect(result[:data]).to eq({})
      end

      it "handles invalid JSON in success response" do
        response = double(status: 200, body: "not-json", headers: json_headers)

        allow(Rails.logger).to receive(:error)

        result = described_class.handle(response)

        expect(result[:success]).to be false
        expect(result[:error]).to eq(I18n.t("humanmark.invalid_response"))
        expect(Rails.logger).to have_received(:error).with(/Invalid JSON response/)
      end
    end

    context "with client error responses" do
      it "handles 400 Bad Request with error message" do
        response = double(
          status: 400,
          body: { error: "Invalid parameters" }.to_json,
          headers: json_headers
        )

        allow(Rails.logger).to receive(:warn)

        result = described_class.handle(response)

        expect(result[:success]).to be false
        expect(result[:error]).to eq("Invalid parameters")
        expect(Rails.logger).to have_received(:warn).with("[Humanmark] Bad request: error=Invalid parameters")
      end

      it "handles 400 with message field" do
        response = double(
          status: 400,
          body: { message: "Bad request message" }.to_json,
          headers: json_headers
        )

        allow(Rails.logger).to receive(:warn)

        result = described_class.handle(response)

        expect(result[:success]).to be false
        expect(result[:error]).to eq("Bad request message")
      end

      it "handles 401 Unauthorized" do
        response = double(
          status: 401,
          body: { error: "Invalid credentials" }.to_json,
          headers: json_headers
        )

        allow(Rails.logger).to receive(:error)

        result = described_class.handle(response)

        expect(result[:success]).to be false
        expect(result[:error]).to eq(I18n.t("humanmark.unauthorized"))
        expect(Rails.logger).to have_received(:error).with("[Humanmark] Unauthorized - check API credentials")
      end

      it "handles 422 Unprocessable Entity" do
        response = double(
          status: 422,
          body: { error: "Validation failed" }.to_json,
          headers: json_headers
        )

        allow(Rails.logger).to receive(:warn)

        result = described_class.handle(response)

        expect(result[:success]).to be false
        expect(result[:error]).to eq("Validation failed")
        expect(Rails.logger).to have_received(:warn).with("[Humanmark] Validation error: error=Validation failed")
      end

      it "handles 429 Rate Limited" do
        response = double(
          status: 429,
          body: { error: "Too many requests" }.to_json,
          headers: { "Retry-After" => "60" }.merge(json_headers)
        )

        allow(Rails.logger).to receive(:warn)

        result = described_class.handle(response)

        expect(result[:success]).to be false
        expect(result[:error]).to eq(I18n.t("humanmark.rate_limited"))
        expect(Rails.logger).to have_received(:warn).with("[Humanmark] Rate limited: retry_after=60")
      end

      it "handles 429 without Retry-After header" do
        response = double(
          status: 429,
          body: { error: "Rate limited" }.to_json,
          headers: json_headers
        )

        allow(Rails.logger).to receive(:warn)

        result = described_class.handle(response)

        expect(result[:success]).to be false
        expect(result[:error]).to eq(I18n.t("humanmark.rate_limited"))
        expect(Rails.logger).to have_received(:warn).with("[Humanmark] Rate limited: retry_after=")
      end
    end

    context "with server error responses" do
      it "handles 500 Internal Server Error" do
        response = double(
          status: 500,
          body: { error: "Server error" }.to_json,
          headers: json_headers
        )

        allow(Rails.logger).to receive(:error)

        result = described_class.handle(response)

        expect(result[:success]).to be false
        expect(result[:error]).to eq(I18n.t("humanmark.server_error"))
        expect(Rails.logger).to have_received(:error).with("[Humanmark] Server error: status=500")
      end

      it "handles 502 Bad Gateway" do
        response = double(
          status: 502,
          body: "<html>502 Bad Gateway</html>",
          headers: { "Content-Type" => "text/html" }
        )

        allow(Rails.logger).to receive(:error)

        result = described_class.handle(response)

        expect(result[:success]).to be false
        expect(result[:error]).to eq(I18n.t("humanmark.server_error"))
        expect(Rails.logger).to have_received(:error).with("[Humanmark] Server error: status=502")
      end

      it "handles 503 Service Unavailable" do
        response = double(
          status: 503,
          body: { error: "Service unavailable" }.to_json,
          headers: json_headers
        )

        allow(Rails.logger).to receive(:error)

        result = described_class.handle(response)

        expect(result[:success]).to be false
        expect(result[:error]).to eq(I18n.t("humanmark.server_error"))
      end
    end

    context "with unexpected responses" do
      it "handles unknown status codes" do
        response = double(
          status: 418, # I'm a teapot
          body: { error: "I'm a teapot" }.to_json,
          headers: json_headers
        )

        allow(Rails.logger).to receive(:error)

        result = described_class.handle(response)

        expect(result[:success]).to be false
        expect(result[:error]).to eq(I18n.t("humanmark.unexpected_error"))
        expect(Rails.logger).to have_received(:error).with("[Humanmark] Unexpected status: status=418")
      end

      it "handles 204 No Content" do
        response = double(
          status: 204,
          body: "",
          headers: {}
        )

        allow(Rails.logger).to receive(:error)

        result = described_class.handle(response)

        expect(result[:success]).to be false
        expect(result[:error]).to eq(I18n.t("humanmark.unexpected_error"))
      end
    end

    context "with error parsing" do
      it "returns unknown error for malformed error response" do
        response = double(
          status: 400,
          body: "not-json",
          headers: json_headers
        )

        allow(Rails.logger).to receive(:warn)

        result = described_class.handle(response)

        expect(result[:success]).to be false
        expect(result[:error]).to eq(I18n.t("humanmark.unknown_error"))
      end

      it "returns unknown error for empty error response" do
        response = double(
          status: 400,
          body: "{}",
          headers: json_headers
        )

        allow(Rails.logger).to receive(:warn)

        result = described_class.handle(response)

        expect(result[:success]).to be false
        expect(result[:error]).to eq(I18n.t("humanmark.unknown_error"))
      end

      it "handles response with nested error structure" do
        response = double(
          status: 400,
          body: { data: { error: "Nested error" } }.to_json,
          headers: json_headers
        )

        allow(Rails.logger).to receive(:warn)

        result = described_class.handle(response)

        expect(result[:success]).to be false
        # parse_error_message only looks for top-level error/message
        expect(result[:error]).to eq(I18n.t("humanmark.unknown_error"))
      end
    end
  end

  describe ".parse_json" do
    it "parses valid JSON" do
      result = described_class.parse_json('{"key": "value"}')
      expect(result).to eq({ "key" => "value" })
    end

    it "returns empty hash for invalid JSON" do
      result = described_class.parse_json("not-json")
      expect(result).to eq({})
    end

    it "returns empty hash for empty string" do
      result = described_class.parse_json("")
      expect(result).to eq({})
    end

    it "returns empty hash for nil" do
      result = described_class.parse_json(nil)
      expect(result).to eq({})
    end
  end

  describe ".parse_error_message" do
    it "extracts error field from response" do
      response = double(body: { error: "Error message" }.to_json)
      result = described_class.parse_error_message(response)
      expect(result).to eq("Error message")
    end

    it "extracts message field from response" do
      response = double(body: { message: "Message text" }.to_json)
      result = described_class.parse_error_message(response)
      expect(result).to eq("Message text")
    end

    it "prefers error over message" do
      response = double(body: { error: "Error", message: "Message" }.to_json)
      result = described_class.parse_error_message(response)
      expect(result).to eq("Error")
    end

    it "returns unknown error for invalid JSON" do
      response = double(body: "not-json")
      result = described_class.parse_error_message(response)
      expect(result).to eq(I18n.t("humanmark.unknown_error"))
    end

    it "returns unknown error when no error fields present" do
      response = double(body: { data: "something" }.to_json)
      result = described_class.parse_error_message(response)
      expect(result).to eq(I18n.t("humanmark.unknown_error"))
    end
  end
end
# rubocop:enable RSpec/VerifiedDoubles
