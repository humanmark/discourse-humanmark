# frozen_string_literal: true

require "final_destination"

module DiscourseHumanmark
  module Http
    class ApiClient
      class ApiError < StandardError; end
      class RetryableError < ApiError; end

      # Thread-safe connection pool
      CONNECTION_POOL_MUTEX = Mutex.new
      @connection_pool = nil

      class << self
        def connection_pool
          return @connection_pool if @connection_pool

          CONNECTION_POOL_MUTEX.synchronize do
            @connection_pool ||= create_connection_pool
          end
        end

        def reset_connection_pool!
          CONNECTION_POOL_MUTEX.synchronize do
            @connection_pool&.reset
            @connection_pool = nil
          end
        end

        private

        def create_connection_pool
          base_url = SiteSetting.humanmark_api_url.presence || "https://humanmark.io"
          uri = URI.parse(base_url)

          # Build URL without explicit port for default ports (helps WebMock matching)
          connection_url = if (uri.scheme == "https" && uri.port == 443) || (uri.scheme == "http" && uri.port == 80)
                             "#{uri.scheme}://#{uri.host}"
                           else
                             "#{uri.scheme}://#{uri.host}:#{uri.port}"
                           end

          Excon.new(connection_url,
                    persistent: true,
                    tcp_nodelay: true,
                    connect_timeout: 10,
                    read_timeout: SiteSetting.humanmark_api_timeout_seconds || 30,
                    write_timeout: SiteSetting.humanmark_api_timeout_seconds || 30,
                    retry_limit: 3,
                    retry_interval: 0.5, # Start with 0.5s delay, Excon will exponentially increase this
                    middlewares: Excon.defaults[:middlewares] + [Excon::Middleware::RedirectFollower],
                    ssl_verify_peer: true,
                    omit_default_port: true)
        end

        public

        def post(endpoint, body = {})
          make_request(:post, endpoint, body)
        end

        private

        def make_request(method, endpoint, body = nil)
          base_url = SiteSetting.humanmark_api_url.presence || "https://humanmark.io"
          url = "#{base_url}#{endpoint}"

          Rails.logger.debug("[Humanmark] API request: method=#{method.upcase} url=#{url}") if SiteSetting.humanmark_debug_mode

          # Validate URL format
          uri = URI.parse(url)
          raise "Invalid URL: must be HTTPS with valid host" unless uri.scheme == "https" && uri.host.present?

          Rails.logger.debug("[Humanmark] URL validated")

          response = execute_request(method, url, body)
          ResponseHandler.handle(response)
        rescue Excon::Error::Timeout
          handle_timeout_error
        rescue Excon::Error => e
          handle_api_error(e)
        rescue StandardError => e
          Rails.logger.error("[Humanmark] URL validation error: error=#{e.message}")
          raise
        end

        def execute_request(method, url, body)
          Rails.logger.debug("[Humanmark] Executing request: method=#{method.upcase} url=#{url}") if SiteSetting.humanmark_debug_mode
          Rails.logger.debug("[Humanmark] Request timeout: seconds=#{SiteSetting.humanmark_api_timeout_seconds || 30}")

          uri = URI.parse(url)
          path = uri.path
          path += "?#{uri.query}" if uri.query

          start_time = Time.current

          # Use connection pool for persistent connections
          response = connection_pool.request(
            method: method,
            path: path,
            body: body&.to_json,
            headers: build_headers,
            expects: [200, 201, 202, 204, 400, 401, 403, 404, 408, 422, 429, 500, 502, 503, 504],
            idempotent: true # Enable automatic retry for this request
          )

          duration_ms = ((Time.current - start_time) * 1000).round(2)
          Rails.logger.debug("[Humanmark] API request completed: method=#{method.upcase} status=#{response.status} duration=#{duration_ms}ms")

          response
        end

        def handle_timeout_error
          Rails.logger.error("[Humanmark] API timeout: seconds=#{SiteSetting.humanmark_api_timeout_seconds || 30}")
          { success: false, error: I18n.t("humanmark.api_timeout") }
        end

        def handle_api_error(error)
          Rails.logger.error("[Humanmark] API error: error=#{error.message}")
          { success: false, error: I18n.t("humanmark.api_error") }
        end

        def build_headers
          {
            "Content-Type" => "application/json",
            "Accept" => "application/json",
            "hm-api-key" => SiteSetting.humanmark_api_key,
            "hm-api-secret" => SiteSetting.humanmark_api_secret,
            "User-Agent" => "Discourse-Humanmark/1.0.0-beta.2"
          }
        end
      end
    end
  end
end
