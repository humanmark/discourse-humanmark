# frozen_string_literal: true

require "jwt"

module DiscourseHumanmark
  module Verification
    class JwtVerifier
      class InvalidTokenError < StandardError; end

      JWT_OPTIONS = {
        algorithm: "HS256",
        verify_expiration: true,
        verify_not_before: true,
        verify_iat: true
      }.freeze

      def self.verify(token, secret)
        validate_inputs(token, secret)
        decode_and_verify(token, secret)
      rescue JWT::ExpiredSignature
        raise InvalidTokenError, "Token has expired"
      rescue JWT::InvalidIatError
        raise InvalidTokenError, "Token issued at time is invalid"
      rescue JWT::VerificationError
        raise InvalidTokenError, "Token signature verification failed"
      rescue JWT::DecodeError => e
        raise InvalidTokenError, "Token decode error: #{e.message}"
      end

      def self.validate_inputs(token, secret)
        raise InvalidTokenError, "Token is blank" if token.blank?
        raise InvalidTokenError, "Secret is blank" if secret.blank?
      end

      def self.decode_and_verify(token, secret)
        payload, _header = JWT.decode(token, secret, true, JWT_OPTIONS)
        validate_payload(payload)
        payload
      end

      def self.validate_payload(payload)
        raise InvalidTokenError, "Token missing subject (challenge)" if payload["sub"].blank?

        return unless payload["exp"] && Time.at(payload["exp"]) < Time.now

        raise InvalidTokenError, "Token has expired"
      end
    end
  end
end
