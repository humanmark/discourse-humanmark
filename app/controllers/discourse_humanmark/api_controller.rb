# frozen_string_literal: true

module DiscourseHumanmark
  class ApiController < ApplicationController
    requires_plugin DiscourseHumanmark::PLUGIN_NAME
    skip_before_action :check_xhr

    # POST /humanmark/flows
    def create_flow
      # Validate context parameter
      if params[:context].blank?
        render_json_error(I18n.t("humanmark.context_required"), status: 400)
        return
      end

      context_sym = params[:context].to_sym
      if %i[post topic message].exclude?(context_sym)
        render_json_error(I18n.t("humanmark.invalid_context"), status: 400)
        return
      end

      # Check if verification is required before creating a flow
      unless Verification::VerificationRequirements.verification_required?(
        context: context_sym,
        user: current_user
      )
        render json: { required: false }
        return
      end

      # Apply rate limiting only for actual verification attempts
      apply_rate_limiting!

      create_and_render_flow
    end

    private

    def apply_rate_limiting!
      # Apply per-user limits for logged-in users
      if current_user
        # Per-user per-minute limit
        begin
          RateLimiter.new(
            current_user,
            "humanmark_challenge_user",
            SiteSetting.humanmark_max_challenges_per_user_per_minute,
            1.minute,
            error_code: "humanmark_rate_limit_exceeded"
          ).performed!
        rescue RateLimiter::LimitExceeded
          Rails.logger.warn("[Humanmark] Rate limit exceeded: type=per_user_minute user_id=#{current_user.id} limit=#{SiteSetting.humanmark_max_challenges_per_user_per_minute}")
          DiscourseEvent.trigger(:humanmark_rate_limited, user_id: current_user.id, ip: request.remote_ip, limit_type: "per_user_minute")
          raise
        end

        # Per-user per-hour limit
        begin
          RateLimiter.new(
            current_user,
            "humanmark_challenge_user_hourly",
            SiteSetting.humanmark_max_challenges_per_user_per_hour,
            1.hour,
            error_code: "humanmark_rate_limit_exceeded"
          ).performed!
        rescue RateLimiter::LimitExceeded
          Rails.logger.warn("[Humanmark] Rate limit exceeded: type=per_user_hour user_id=#{current_user.id} limit=#{SiteSetting.humanmark_max_challenges_per_user_per_hour}")
          DiscourseEvent.trigger(:humanmark_rate_limited, user_id: current_user.id, ip: request.remote_ip, limit_type: "per_user_hour")
          raise
        end
      end

      # Apply per-IP limits for all users (more generous to handle shared IPs)
      # Per-IP per-minute limit
      begin
        RateLimiter.new(
          nil,
          "humanmark_challenge_#{request.remote_ip}_per_min",
          SiteSetting.humanmark_max_challenges_per_ip_per_minute,
          1.minute,
          error_code: "humanmark_rate_limit_exceeded"
        ).performed!
      rescue RateLimiter::LimitExceeded
        Rails.logger.warn("[Humanmark] Rate limit exceeded: type=per_ip_minute ip=#{request.remote_ip} user_id=#{current_user&.id || 'anonymous'} limit=#{SiteSetting.humanmark_max_challenges_per_ip_per_minute}")
        DiscourseEvent.trigger(:humanmark_rate_limited, user_id: current_user&.id, ip: request.remote_ip, limit_type: "per_ip_minute")
        raise
      end

      # Per-IP per-hour limit
      begin
        RateLimiter.new(
          nil,
          "humanmark_challenge_#{request.remote_ip}_per_hour",
          SiteSetting.humanmark_max_challenges_per_ip_per_hour,
          1.hour,
          error_code: "humanmark_rate_limit_exceeded"
        ).performed!
      rescue RateLimiter::LimitExceeded
        Rails.logger.warn("[Humanmark] Rate limit exceeded: type=per_ip_hour ip=#{request.remote_ip} user_id=#{current_user&.id || 'anonymous'} limit=#{SiteSetting.humanmark_max_challenges_per_ip_per_hour}")
        DiscourseEvent.trigger(:humanmark_rate_limited, user_id: current_user&.id, ip: request.remote_ip, limit_type: "per_ip_hour")
        raise
      end
    rescue RateLimiter::LimitExceeded => e
      render_json_error(
        I18n.t("humanmark.rate_limit_exceeded",
               time_left: e.time_left.round),
        status: 429
      )
    end

    def create_and_render_flow
      result = FlowService.call(
        action: :create,
        context: params[:context].to_sym,
        user: current_user
      )

      if result[:success]
        render json: {
          required: true,
          token: result[:token],
          challenge: result[:flow].challenge
        }
      else
        render_json_error(result[:error], status: 422)
      end
    end
  end
end
