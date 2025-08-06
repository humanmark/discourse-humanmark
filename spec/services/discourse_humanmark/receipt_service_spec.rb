# frozen_string_literal: true

RSpec.describe DiscourseHumanmark::ReceiptService do
  fab!(:user)

  before do
    SiteSetting.humanmark_enabled = true
    SiteSetting.humanmark_api_key = "test-key"
    SiteSetting.humanmark_api_secret = "test-secret"
  end

  describe "#call" do
    context "with valid receipt" do
      let(:challenge) { "test-challenge-123" }
      let(:valid_payload) do
        {
          sub: challenge,
          iat: Time.now.to_i,
          exp: 1.hour.from_now.to_i
        }
      end
      let(:valid_receipt) { generate_jwt(valid_payload, SiteSetting.humanmark_api_secret) }

      it "returns success with challenge and payload" do
        result = described_class.call(receipt: valid_receipt, context: :post)

        expect(result[:success]).to be true
        expect(result[:challenge]).to eq(challenge)
        expect(result[:payload]["sub"]).to eq(challenge)
      end

      it "logs debug message when debug mode enabled" do
        SiteSetting.humanmark_debug_mode = true
        allow(Rails.logger).to receive(:debug)

        described_class.call(receipt: valid_receipt, context: :post)

        expect(Rails.logger).to have_received(:debug).with("[Humanmark] Receipt verified: challenge=test-cha...")
      end
    end

    context "with invalid receipt" do
      it "returns error for invalid JWT signature" do
        invalid_receipt = generate_jwt({ sub: "challenge" }, "wrong-secret")

        result = described_class.call(receipt: invalid_receipt, context: :post)

        expect(result[:success]).to be false
        expect(result[:error]).to eq(I18n.t("humanmark.invalid_receipt"))
      end

      it "returns error for missing sub claim" do
        # Mock JwtVerifier to simulate a missing sub claim scenario
        # In practice, JwtVerifier will throw an exception which ReceiptService catches
        allow(DiscourseHumanmark::Verification::JwtVerifier).to receive(:verify)
          .and_raise(DiscourseHumanmark::Verification::JwtVerifier::InvalidTokenError, "Token missing subject")

        result = described_class.call(receipt: "any-token", context: :post)

        expect(result[:success]).to be false
        expect(result[:error]).to eq(I18n.t("humanmark.invalid_receipt"))
      end

      it "returns error for blank sub claim" do
        payload_with_blank_sub = {
          sub: "",
          iat: Time.now.to_i,
          exp: 1.hour.from_now.to_i
        }
        receipt = generate_jwt(payload_with_blank_sub, SiteSetting.humanmark_api_secret)

        result = described_class.call(receipt: receipt, context: :post)

        expect(result[:success]).to be false
        expect(result[:error]).to eq(I18n.t("humanmark.invalid_receipt"))
      end

      it "logs warning for invalid receipt" do
        allow(Rails.logger).to receive(:warn)
        invalid_receipt = generate_jwt({ sub: "challenge" }, "wrong-secret")

        described_class.call(receipt: invalid_receipt, context: :post)

        expect(Rails.logger).to have_received(:warn).with(/\[Humanmark\] Invalid receipt: error=/)
      end

      it "returns error for malformed JWT" do
        malformed_receipt = "not.a.jwt"

        result = described_class.call(receipt: malformed_receipt, context: :post)

        expect(result[:success]).to be false
        expect(result[:error]).to eq(I18n.t("humanmark.invalid_receipt"))
      end

      it "returns error for expired token" do
        expired_payload = {
          sub: "challenge",
          iat: 2.hours.ago.to_i,
          exp: 1.hour.ago.to_i
        }
        expired_receipt = generate_jwt(expired_payload, SiteSetting.humanmark_api_secret)

        result = described_class.call(receipt: expired_receipt, context: :post)

        expect(result[:success]).to be false
        expect(result[:error]).to eq(I18n.t("humanmark.invalid_receipt"))
      end
    end

    context "with missing parameters" do
      it "returns error when receipt is blank" do
        result = described_class.call(receipt: "", context: :post)

        expect(result[:success]).to be false
        expect(result[:error]).to include("Receipt can't be blank")
      end

      it "returns error when receipt is nil" do
        result = described_class.call(receipt: nil, context: :post)

        expect(result[:success]).to be false
        expect(result[:error]).to include("Receipt can't be blank")
      end

      it "returns error when context is blank" do
        valid_receipt = generate_jwt({ sub: "challenge" }, SiteSetting.humanmark_api_secret)

        result = described_class.call(receipt: valid_receipt, context: nil)

        expect(result[:success]).to be false
        expect(result[:error]).to include("Context can't be blank")
      end
    end

    context "with JWT edge cases" do
      it "handles JWT with extra claims" do
        payload_with_extras = {
          sub: "challenge-123",
          iat: Time.now.to_i,
          exp: 1.hour.from_now.to_i,
          extra_claim: "should be ignored",
          user_data: { id: 123, name: "test" },
          scopes: %w[read write]
        }
        receipt = generate_jwt(payload_with_extras, SiteSetting.humanmark_api_secret)

        result = described_class.call(receipt: receipt, context: :post)

        expect(result[:success]).to be true
        expect(result[:challenge]).to eq("challenge-123")
        # Extra claims should be preserved in payload
        expect(result[:payload]["extra_claim"]).to eq("should be ignored")
        expect(result[:payload]["user_data"]).to eq({ "id" => 123, "name" => "test" })
      end

      it "handles JWT with minimal claims (only sub)" do
        minimal_payload = { sub: "minimal-challenge" }
        receipt = generate_jwt(minimal_payload, SiteSetting.humanmark_api_secret)

        result = described_class.call(receipt: receipt, context: :post)

        expect(result[:success]).to be true
        expect(result[:challenge]).to eq("minimal-challenge")
        expect(result[:payload]["sub"]).to eq("minimal-challenge")
      end

      it "handles JWT with nested sub claim structure" do
        # Some JWT libraries might encode sub differently
        complex_payload = {
          sub: { challenge: "nested", timestamp: Time.now.to_i }.to_json,
          iat: Time.now.to_i
        }
        receipt = generate_jwt(complex_payload, SiteSetting.humanmark_api_secret)

        result = described_class.call(receipt: receipt, context: :post)

        # Should extract the stringified JSON as the challenge
        expect(result[:success]).to be true
        expect(result[:challenge]).to be_a(String)
        expect(result[:challenge]).to include("nested")
      end

      it "handles JWT with integer sub claim" do
        # Sub claim might be numeric in some cases
        numeric_payload = {
          sub: 123_456_789,
          iat: Time.now.to_i
        }
        receipt = generate_jwt(numeric_payload, SiteSetting.humanmark_api_secret)

        result = described_class.call(receipt: receipt, context: :post)

        expect(result[:success]).to be true
        expect(result[:challenge]).to eq("123456789") # Converted to string
      end

      it "handles JWT with very long sub claim" do
        long_challenge = "a" * 1000
        long_payload = {
          sub: long_challenge,
          iat: Time.now.to_i
        }
        receipt = generate_jwt(long_payload, SiteSetting.humanmark_api_secret)

        result = described_class.call(receipt: receipt, context: :post)

        expect(result[:success]).to be true
        expect(result[:challenge]).to eq(long_challenge)
        expect(result[:challenge].length).to eq(1000)
      end

      it "handles JWT with special characters in sub" do
        special_payload = {
          sub: "test-😀-challenge-\n-\t-<script>",
          iat: Time.now.to_i
        }
        receipt = generate_jwt(special_payload, SiteSetting.humanmark_api_secret)

        result = described_class.call(receipt: receipt, context: :post)

        expect(result[:success]).to be true
        expect(result[:challenge]).to eq("test-😀-challenge-\n-\t-<script>")
      end

      it "rejects JWT with null sub claim" do
        # Create a custom JWT with null sub
        null_payload = {
          sub: nil,
          iat: Time.now.to_i
        }
        receipt = generate_jwt(null_payload, SiteSetting.humanmark_api_secret)

        result = described_class.call(receipt: receipt, context: :post)

        expect(result[:success]).to be false
        expect(result[:error]).to eq(I18n.t("humanmark.invalid_receipt"))
      end

      it "handles JWT at exact expiration boundary" do
        boundary_payload = {
          sub: "boundary-challenge",
          iat: Time.now.to_i,
          exp: Time.now.to_i # Expires right now
        }
        receipt = generate_jwt(boundary_payload, SiteSetting.humanmark_api_secret)

        # Might succeed or fail depending on exact timing, but shouldn't crash
        result = described_class.call(receipt: receipt, context: :post)

        expect(result).to have_key(:success)
        expect(result).to have_key(:error) unless result[:success]
      end
    end

    context "with different contexts" do
      let(:valid_receipt) { generate_jwt({ sub: "challenge" }, SiteSetting.humanmark_api_secret) }

      it "accepts post context" do
        result = described_class.call(receipt: valid_receipt, context: :post)
        expect(result[:success]).to be true
      end

      it "accepts topic context" do
        result = described_class.call(receipt: valid_receipt, context: :topic)
        expect(result[:success]).to be true
      end

      it "accepts message context" do
        result = described_class.call(receipt: valid_receipt, context: :message)
        expect(result[:success]).to be true
      end
    end
  end
end
