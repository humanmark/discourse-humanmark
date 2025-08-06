# frozen_string_literal: true

RSpec.describe DiscourseHumanmark::Verification::JwtVerifier do
  let(:secret) { "test-secret-key" }
  let(:valid_payload) do
    {
      sub: "challenge-123",
      iat: Time.now.to_i,
      exp: 1.hour.from_now.to_i,
      custom: "data"
    }
  end

  describe ".verify" do
    context "with valid token" do
      let(:valid_token) { JWT.encode(valid_payload, secret, "HS256") }

      it "returns the decoded payload" do
        result = described_class.verify(valid_token, secret)

        expect(result["sub"]).to eq("challenge-123")
        expect(result["custom"]).to eq("data")
        expect(result["iat"]).to eq(valid_payload[:iat])
        expect(result["exp"]).to eq(valid_payload[:exp])
      end

      it "accepts tokens with additional claims" do
        payload_with_extras = valid_payload.merge(
          extra1: "value1",
          extra2: "value2"
        )
        token = JWT.encode(payload_with_extras, secret, "HS256")

        result = described_class.verify(token, secret)

        expect(result["sub"]).to eq("challenge-123")
        expect(result["extra1"]).to eq("value1")
        expect(result["extra2"]).to eq("value2")
      end
    end

    context "with invalid signature" do
      let(:token_with_wrong_secret) { JWT.encode(valid_payload, "wrong-secret", "HS256") }

      it "raises InvalidTokenError" do
        expect do
          described_class.verify(token_with_wrong_secret, secret)
        end.to raise_error(
          DiscourseHumanmark::Verification::JwtVerifier::InvalidTokenError,
          "Token signature verification failed"
        )
      end
    end

    context "with expired token" do
      let(:expired_payload) do
        {
          sub: "challenge-123",
          iat: 2.hours.ago.to_i,
          exp: 1.hour.ago.to_i
        }
      end
      let(:expired_token) { JWT.encode(expired_payload, secret, "HS256") }

      it "raises InvalidTokenError with expiration message" do
        expect do
          described_class.verify(expired_token, secret)
        end.to raise_error(
          DiscourseHumanmark::Verification::JwtVerifier::InvalidTokenError,
          "Token has expired"
        )
      end
    end

    context "with malformed token" do
      it "raises InvalidTokenError for invalid base64" do
        malformed_token = "not.a.valid.jwt"

        expect do
          described_class.verify(malformed_token, secret)
        end.to raise_error(
          DiscourseHumanmark::Verification::JwtVerifier::InvalidTokenError,
          /Token decode error/
        )
      end

      it "raises InvalidTokenError for non-JWT string" do
        expect do
          described_class.verify("just-a-random-string", secret)
        end.to raise_error(
          DiscourseHumanmark::Verification::JwtVerifier::InvalidTokenError,
          /Token decode error/
        )
      end

      it "raises InvalidTokenError for nil token" do
        expect do
          described_class.verify(nil, secret)
        end.to raise_error(
          DiscourseHumanmark::Verification::JwtVerifier::InvalidTokenError,
          "Token is blank"
        )
      end

      it "raises InvalidTokenError for empty string" do
        expect do
          described_class.verify("", secret)
        end.to raise_error(
          DiscourseHumanmark::Verification::JwtVerifier::InvalidTokenError,
          "Token is blank"
        )
      end
    end

    context "with different algorithms" do
      it "rejects tokens signed with RS256" do
        # Generate RSA keys for testing
        rsa_private = OpenSSL::PKey::RSA.generate(2048)
        rsa_public = rsa_private.public_key

        # Create token with RS256
        rs256_token = JWT.encode(valid_payload, rsa_private, "RS256")

        # Should reject even if someone tries to verify with the public key
        expect do
          described_class.verify(rs256_token, rsa_public.to_s)
        end.to raise_error(
          DiscourseHumanmark::Verification::JwtVerifier::InvalidTokenError
        )
      end

      it "only accepts HS256 algorithm" do
        # Try to create a token with HS512
        hs512_token = JWT.encode(valid_payload, secret, "HS512")

        # Should reject because we only accept HS256
        expect do
          described_class.verify(hs512_token, secret)
        end.to raise_error(
          DiscourseHumanmark::Verification::JwtVerifier::InvalidTokenError,
          /Token decode error/
        )
      end
    end

    context "with missing claims" do
      it "requires sub claim for verification" do
        minimal_payload = { data: "test" }
        token = JWT.encode(minimal_payload, secret, "HS256")

        expect do
          described_class.verify(token, secret)
        end.to raise_error(
          DiscourseHumanmark::Verification::JwtVerifier::InvalidTokenError,
          "Token missing subject (challenge)"
        )
      end

      it "requires sub claim even with other data" do
        payload_without_sub = {
          data: "test",
          iat: Time.now.to_i,
          exp: 1.hour.from_now.to_i
        }
        token = JWT.encode(payload_without_sub, secret, "HS256")

        expect do
          described_class.verify(token, secret)
        end.to raise_error(
          DiscourseHumanmark::Verification::JwtVerifier::InvalidTokenError,
          "Token missing subject (challenge)"
        )
      end
    end

    context "with timing issues" do
      it "rejects tokens with iat in the future" do
        future_payload = {
          sub: "challenge-123",
          iat: 30.seconds.from_now.to_i,
          exp: 1.hour.from_now.to_i
        }
        token = JWT.encode(future_payload, secret, "HS256")

        # Should reject future iat
        expect do
          described_class.verify(token, secret)
        end.to raise_error(
          DiscourseHumanmark::Verification::JwtVerifier::InvalidTokenError,
          "Token issued at time is invalid"
        )
      end

      it "accepts tokens without exp claim" do
        payload_without_exp = {
          sub: "challenge-123",
          iat: Time.now.to_i
        }
        token = JWT.encode(payload_without_exp, secret, "HS256")

        result = described_class.verify(token, secret)
        expect(result["sub"]).to eq("challenge-123")
      end
    end

    context "with nil or blank secret" do
      it "raises InvalidTokenError for nil secret" do
        token = JWT.encode(valid_payload, secret, "HS256")

        expect do
          described_class.verify(token, nil)
        end.to raise_error(
          DiscourseHumanmark::Verification::JwtVerifier::InvalidTokenError,
          "Secret is blank"
        )
      end

      it "raises InvalidTokenError for empty secret" do
        token = JWT.encode(valid_payload, secret, "HS256")

        expect do
          described_class.verify(token, "")
        end.to raise_error(
          DiscourseHumanmark::Verification::JwtVerifier::InvalidTokenError,
          "Secret is blank"
        )
      end
    end
  end

  describe ".validate_payload" do
    it "is called internally during verification" do
      token = JWT.encode(valid_payload, secret, "HS256")

      # validate_payload is a private method, but we can test its effect
      # by ensuring the verification succeeds
      result = described_class.verify(token, secret)
      expect(result).to be_present
    end
  end
end
