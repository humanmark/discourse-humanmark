# frozen_string_literal: true

# This file sets up the test environment for running tests standalone
# Note: For full integration testing, install this plugin in a Discourse instance

require "rspec"
require "webmock/rspec"
require "json"
require "securerandom"

# Stub Rails and Discourse components for standalone testing
module Rails
  def self.logger
    @logger ||= Logger.new($stdout)
  end

  def self.root
    Pathname.new(File.expand_path("../../..", __dir__))
  end
end

module SiteSetting
  @settings = {
    humanmark_enabled: false,
    humanmark_api_key: "",
    humanmark_api_secret: "",
    humanmark_api_url: "https://humanmark.io",
    humanmark_domain: "",
    humanmark_protect_posts: false,
    humanmark_protect_topics: false,
    humanmark_protect_messages: false,
    humanmark_bypass_staff: true,
    humanmark_bypass_trust_level: 3,
    humanmark_reverify_period_posts: 30,
    humanmark_reverify_period_topics: 0,
    humanmark_reverify_period_messages: 60,
    humanmark_flow_retention_days: 30,
    humanmark_max_challenges_per_ip_per_minute: 5,
    humanmark_max_challenges_per_ip_per_hour: 20,
    humanmark_api_timeout_seconds: 30
  }

  def self.method_missing(method, *args)
    if method.to_s.end_with?("=")
      setting = method.to_s.chomp("=").to_sym
      @settings[setting] = args.first
    else
      @settings[method]
    end
  end

  def self.respond_to_missing?(_method, _include_private = false)
    true
  end

  def self.public_send(method, *)
    send(method, *)
  end
end

# Mock ActiveRecord for standalone tests
module ActiveRecord
  class Base
    class << self
      attr_writer :table_name
    end

    class << self
      attr_reader :table_name
    end
  end

  class RecordNotFound < StandardError; end
  class RecordInvalid < StandardError; end
  class StaleObjectError < StandardError; end
end

# Mock Discourse components
module DiscourseEvent
  def self.trigger(event, *args); end
end

class RateLimiter
  class LimitExceeded < StandardError
    attr_reader :time_left

    def initialize(time_left)
      @time_left = time_left
      super("Rate limit exceeded")
    end
  end

  def initialize(*args); end
  def performed!; end
end

class DistributedMutex
  def initialize(key, validity = 60); end

  def synchronize
    yield
  end
end

# Mock JWT for testing
module JWT
  def self.encode(payload, secret, algorithm = "HS256")
    Base64.encode64({ payload: payload, secret: secret, algorithm: algorithm }.to_json).strip
  end

  def self.decode(token, secret, verify: true, **_options)
    data = JSON.parse(Base64.decode64(token))
    raise JWT::VerificationError, "Signature verification failed" if verify && data["secret"] != secret
    raise JWT::ExpiredSignature, "Token has expired" if data["payload"]["exp"] && data["payload"]["exp"] < Time.now.to_i

    [data["payload"], { "alg" => data["algorithm"] }]
  rescue StandardError => e
    raise JWT::DecodeError, "Invalid token: #{e.message}"
  end

  class DecodeError < StandardError; end
  class VerificationError < DecodeError; end
  class ExpiredSignature < DecodeError; end
end

# Mock I18n
module I18n
  def self.t(key, _options = {})
    key.to_s.split(".").last.humanize
  end
end

# Load plugin files with minimal dependencies
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
$LOAD_PATH.unshift(File.expand_path("../app/models", __dir__))
$LOAD_PATH.unshift(File.expand_path("../app/services", __dir__))

# Include test helpers
Dir[File.expand_path("**/*_helper.rb", __dir__)].each { |f| require f }

# Configure RSpec
RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.filter_run_when_matching :focus
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end

puts "Note: Running in standalone test mode with mocked Discourse components."
puts "For full integration testing, install this plugin in a Discourse instance."
