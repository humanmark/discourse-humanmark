# frozen_string_literal: true

# name: discourse-humanmark
# about: Know what's human in your forum - hardware-backed verification of human intent
# version: 1.0.0-beta.1
# authors: Humanmark SPC
# url: https://github.com/humanmark/discourse-humanmark
# required_version: 3.0.0

module ::DiscourseHumanmark
  PLUGIN_NAME = "discourse-humanmark"
end

require_relative "lib/discourse_humanmark/engine"

enabled_site_setting :humanmark_enabled

after_initialize do
  # Load lib components that aren't autoloaded
  %w[
    lib/discourse_humanmark/http/response_handler
    lib/discourse_humanmark/http/api_client
    lib/discourse_humanmark/verification/jwt_verifier
    lib/discourse_humanmark/verification/verification_requirements
    lib/discourse_humanmark/integrations/base
    lib/discourse_humanmark/integrations/content
  ].each do |path|
    require_relative path
  end

  # Register integrations with event handlers
  # Content integrations
  # Register handler unconditionally - it will check settings dynamically
  on(:before_create_post) do |post, opts|
    next if post.id.present? # Skip if editing
    next unless SiteSetting.humanmark_enabled
    next unless SiteSetting.humanmark_protect_posts || SiteSetting.humanmark_protect_topics || SiteSetting.humanmark_protect_messages

    content_type = DiscourseHumanmark::Integrations::Content.determine_content_type(post)
    next unless content_type

    DiscourseHumanmark::Integrations::Content.verify_action(
      context: content_type,
      user: post.user,
      receipt: opts[:humanmark_receipt]
    )
  end

  # Register assets
  register_asset "stylesheets/humanmark.scss"

  # Register post parameters
  # Must be registered unconditionally so they work when plugin is enabled dynamically
  add_permitted_post_create_param(:humanmark_receipt)

  # Reset connection pool when API settings change
  on(:site_setting_changed) do |name, old_value, new_value|
    if %i[humanmark_api_url humanmark_api_timeout_seconds].include?(name)
      Rails.logger.info("[Humanmark] Connection pool reset: setting=#{name} old_value=#{old_value} new_value=#{new_value}")
      DiscourseHumanmark::Http::ApiClient.reset_connection_pool!
    end
  end

  # Event consumers for admin reporting
  # Track flow events
  on(:humanmark_flow_created) do |params|
    key = "flows_created"
    date = Date.today.to_s
    count = PluginStore.get(DiscourseHumanmark::PLUGIN_NAME, "#{key}:#{date}") || 0
    PluginStore.set(DiscourseHumanmark::PLUGIN_NAME, "#{key}:#{date}", count + 1)

    if params[:context]
      context_key = "context_#{params[:context]}_created"
      context_count = PluginStore.get(DiscourseHumanmark::PLUGIN_NAME, "#{context_key}:#{date}") || 0
      PluginStore.set(DiscourseHumanmark::PLUGIN_NAME, "#{context_key}:#{date}", context_count + 1)
    end
  end

  on(:humanmark_flow_completed) do |params|
    date = Date.today.to_s
    key = "flows_completed"
    count = PluginStore.get(DiscourseHumanmark::PLUGIN_NAME, "#{key}:#{date}") || 0
    PluginStore.set(DiscourseHumanmark::PLUGIN_NAME, "#{key}:#{date}", count + 1)

    if params[:context]
      context_key = "context_#{params[:context]}_completed"
      context_count = PluginStore.get(DiscourseHumanmark::PLUGIN_NAME, "#{context_key}:#{date}") || 0
      PluginStore.set(DiscourseHumanmark::PLUGIN_NAME, "#{context_key}:#{date}", context_count + 1)
    end
  end

  on(:humanmark_flow_expired) do |params|
    date = Date.today.to_s
    key = "flows_expired"
    count = PluginStore.get(DiscourseHumanmark::PLUGIN_NAME, "#{key}:#{date}") || 0
    PluginStore.set(DiscourseHumanmark::PLUGIN_NAME, "#{key}:#{date}", count + 1)

    if params[:context]
      context_key = "context_#{params[:context]}_expired"
      context_count = PluginStore.get(DiscourseHumanmark::PLUGIN_NAME, "#{context_key}:#{date}") || 0
      PluginStore.set(DiscourseHumanmark::PLUGIN_NAME, "#{context_key}:#{date}", context_count + 1)
    end
  end

  # Track verification events
  on(:humanmark_verification_completed) do |params|
    date = Date.today.to_s
    key = "verifications_completed"
    count = PluginStore.get(DiscourseHumanmark::PLUGIN_NAME, "#{key}:#{date}") || 0
    PluginStore.set(DiscourseHumanmark::PLUGIN_NAME, "#{key}:#{date}", count + 1)

    if params[:context]
      context_key = "context_#{params[:context]}_verified"
      context_count = PluginStore.get(DiscourseHumanmark::PLUGIN_NAME, "#{context_key}:#{date}") || 0
      PluginStore.set(DiscourseHumanmark::PLUGIN_NAME, "#{context_key}:#{date}", context_count + 1)
    end
  end

  on(:humanmark_verification_failed) do |params|
    date = Date.today.to_s
    key = "verifications_failed"
    count = PluginStore.get(DiscourseHumanmark::PLUGIN_NAME, "#{key}:#{date}") || 0
    PluginStore.set(DiscourseHumanmark::PLUGIN_NAME, "#{key}:#{date}", count + 1)

    if params[:context]
      context_key = "context_#{params[:context]}_failed"
      context_count = PluginStore.get(DiscourseHumanmark::PLUGIN_NAME, "#{context_key}:#{date}") || 0
      PluginStore.set(DiscourseHumanmark::PLUGIN_NAME, "#{context_key}:#{date}", context_count + 1)
    end
  end

  # Track bypasses
  on(:humanmark_verification_bypassed) do |params|
    date = Date.today.to_s

    key = "verifications_bypassed"
    count = PluginStore.get(DiscourseHumanmark::PLUGIN_NAME, "#{key}:#{date}") || 0
    PluginStore.set(DiscourseHumanmark::PLUGIN_NAME, "#{key}:#{date}", count + 1)

    if params[:reason]
      reason_key = "bypass_reason_#{params[:reason]}"
      reason_count = PluginStore.get(DiscourseHumanmark::PLUGIN_NAME, "#{reason_key}:#{date}") || 0
      PluginStore.set(DiscourseHumanmark::PLUGIN_NAME, "#{reason_key}:#{date}", reason_count + 1)
    end

    if params[:context]
      context_key = "context_#{params[:context]}_bypassed"
      context_count = PluginStore.get(DiscourseHumanmark::PLUGIN_NAME, "#{context_key}:#{date}") || 0
      PluginStore.set(DiscourseHumanmark::PLUGIN_NAME, "#{context_key}:#{date}", context_count + 1)
    end
  end

  # Track rate limits
  on(:humanmark_rate_limited) do |params|
    date = Date.today.to_s

    key = "rate_limits_hit"
    count = PluginStore.get(DiscourseHumanmark::PLUGIN_NAME, "#{key}:#{date}") || 0
    PluginStore.set(DiscourseHumanmark::PLUGIN_NAME, "#{key}:#{date}", count + 1)

    if params[:limit_type]
      type_key = "rate_limit_#{params[:limit_type]}"
      type_count = PluginStore.get(DiscourseHumanmark::PLUGIN_NAME, "#{type_key}:#{date}") || 0
      PluginStore.set(DiscourseHumanmark::PLUGIN_NAME, "#{type_key}:#{date}", type_count + 1)
    end
  end

  # Admin reports
  add_report("humanmark_activity") do |report|
    report.icon = "shield-check"
    report.modes = [:stacked_chart]

    start_date = report.start_date.to_date
    end_date = report.end_date.to_date

    # Build data for multiple series
    created_data = []
    completed_data = []
    expired_data = []
    bypassed_data = []

    (start_date..end_date).each do |date|
      date_str = date.to_s
      created = PluginStore.get(DiscourseHumanmark::PLUGIN_NAME, "flows_created:#{date_str}") || 0
      completed = PluginStore.get(DiscourseHumanmark::PLUGIN_NAME, "flows_completed:#{date_str}") || 0
      expired = PluginStore.get(DiscourseHumanmark::PLUGIN_NAME, "flows_expired:#{date_str}") || 0
      bypassed = PluginStore.get(DiscourseHumanmark::PLUGIN_NAME, "verifications_bypassed:#{date_str}") || 0

      created_data << { x: date.to_s, y: created }
      completed_data << { x: date.to_s, y: completed }
      expired_data << { x: date.to_s, y: expired }
      bypassed_data << { x: date.to_s, y: bypassed }
    end

    # Set up multiple data series - stacked_chart format
    report.data = [
      {
        req: "created",
        label: "Created",
        color: report.colors[:turquoise],
        data: created_data
      },
      {
        req: "completed",
        label: "Completed",
        color: report.colors[:lime],
        data: completed_data
      },
      {
        req: "expired",
        label: "Expired",
        color: report.colors[:magenta],
        data: expired_data
      },
      {
        req: "bypassed",
        label: "Bypassed",
        color: report.colors[:purple],
        data: bypassed_data
      }
    ]

    # Summary stats
    total_created = created_data.sum { |d| d[:y] }
    report.total = total_created
    report.prev30Days = created_data.last(30).sum { |d| d[:y] }
  end

  add_report("humanmark_contexts") do |report|
    report.icon = "shield-check"
    report.modes = [:table]

    # Define table columns
    report.labels = [
      { property: :context, title: "Context" },
      { property: :total, title: "Total", type: :number },
      { property: :created, title: "Created", type: :number },
      { property: :completed, title: "Completed", type: :number },
      { property: :expired, title: "Expired", type: :number },
      { property: :bypassed, title: "Bypassed", type: :number },
      { property: :success_rate, title: "Success %", type: :number }
    ]

    start_date = report.start_date.to_date
    end_date = report.end_date.to_date

    contexts = %w[post topic message]
    data = []

    contexts.each do |context|
      created = 0
      completed = 0
      expired = 0
      bypassed = 0

      (start_date..end_date).each do |date|
        date_str = date.to_s
        created += PluginStore.get(DiscourseHumanmark::PLUGIN_NAME, "context_#{context}_created:#{date_str}") || 0
        completed += PluginStore.get(DiscourseHumanmark::PLUGIN_NAME, "context_#{context}_completed:#{date_str}") || 0
        expired += PluginStore.get(DiscourseHumanmark::PLUGIN_NAME, "context_#{context}_expired:#{date_str}") || 0
        bypassed += PluginStore.get(DiscourseHumanmark::PLUGIN_NAME, "context_#{context}_bypassed:#{date_str}") || 0
      end

      total = created + bypassed
      success_rate = created.positive? ? ((completed.to_f / created) * 100).round(1) : 0

      data << {
        context: context.capitalize,
        total: total,
        created: created,
        completed: completed,
        expired: expired,
        bypassed: bypassed,
        success_rate: success_rate
      }
    end

    report.data = data
  end

  add_report("humanmark_bypasses") do |report|
    report.icon = "shield-check"
    report.modes = [:table]

    # Define table columns
    report.labels = [
      { property: :reason, title: "Bypass Reason" },
      { property: :count, title: "Count", type: :number }
    ]

    start_date = report.start_date.to_date
    end_date = report.end_date.to_date

    reasons = %w[staff trust_level recent_verification]
    data = []
    total_count = 0

    reasons.each do |reason|
      count = 0
      (start_date..end_date).each do |date|
        date_str = date.to_s
        count += PluginStore.get(DiscourseHumanmark::PLUGIN_NAME, "bypass_reason_#{reason}:#{date_str}") || 0
      end

      total_count += count
      data << {
        reason: reason.humanize,
        count: count
      }
    end

    report.data = data
    report.total = total_count
  end

  add_report("humanmark_rate_limits") do |report|
    report.icon = "shield-check"
    report.modes = [:table]

    # Define table columns
    report.labels = [
      { property: :type, title: "Limit Type" },
      { property: :count, title: "Times Hit", type: :number }
    ]

    start_date = report.start_date.to_date
    end_date = report.end_date.to_date

    limit_types = %w[per_user_minute per_user_hour per_ip_minute per_ip_hour]
    data = []
    total_count = 0

    limit_types.each do |limit_type|
      count = 0
      (start_date..end_date).each do |date|
        date_str = date.to_s
        count += PluginStore.get(DiscourseHumanmark::PLUGIN_NAME, "rate_limit_#{limit_type}:#{date_str}") || 0
      end

      total_count += count
      data << {
        type: limit_type.humanize,
        count: count
      }
    end

    report.data = data
    report.total = total_count
  end
end
