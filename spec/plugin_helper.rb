# frozen_string_literal: true

# This file is automatically loaded by Discourse when running plugin tests

module HumanmarkTestHelpers
  def create_flow(attrs = {})
    default_attrs = {
      challenge: SecureRandom.hex(16),
      token: SecureRandom.hex(32),
      context: "post",
      status: "pending",
      user_id: nil
    }
    DiscourseHumanmark::Flow.create!(default_attrs.merge(attrs))
  end

  def mock_humanmark_api_response(success: true, challenge: nil, token: nil)
    challenge ||= SecureRandom.hex(16)
    token ||= SecureRandom.hex(32)

    if success
      {
        status: 200,
        body: {
          success: true,
          challenge: challenge,
          token: token
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      }
    else
      {
        status: 400,
        body: {
          success: false,
          error: "Invalid request"
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      }
    end
  end

  def generate_jwt(payload = {}, secret = nil)
    secret ||= SiteSetting.humanmark_api_secret || "test-secret"
    default_payload = {
      sub: SecureRandom.hex(16),
      iat: Time.now.to_i,
      exp: 1.hour.from_now.to_i
    }
    JWT.encode(default_payload.merge(payload), secret, "HS256")
  end

  def generate_invalid_jwt
    JWT.encode({ sub: "test" }, "wrong-secret", "HS256")
  end

  def stub_humanmark_api_request(success: true, challenge: nil, token: nil)
    # Use WebMock to stub the HTTP request
    # This works with both regular Excon and persistent connections
    stub_request(:post, "#{SiteSetting.humanmark_api_url}/api/v1/challenge/create")
      .to_return { mock_humanmark_api_response(success: success, challenge: challenge, token: token) }
  end

  def with_humanmark_enabled
    SiteSetting.humanmark_enabled = true
    SiteSetting.humanmark_api_key = "test-api-key"
    SiteSetting.humanmark_api_secret = "test-api-secret"
    yield
  ensure
    SiteSetting.humanmark_enabled = false
  end

  def simulate_rate_limit(times, &)
    times.times(&)
  end
end

RSpec.configure do |config|
  config.include HumanmarkTestHelpers

  config.before(:each) do |example|
    if example.metadata[:humanmark]
      SiteSetting.humanmark_enabled = true
      SiteSetting.humanmark_api_key = "test-key"
      SiteSetting.humanmark_api_secret = "test-secret"
    end
  end

  config.after(:each) do |example|
    DiscourseHumanmark::Flow.destroy_all if example.metadata[:humanmark]
  end
end
