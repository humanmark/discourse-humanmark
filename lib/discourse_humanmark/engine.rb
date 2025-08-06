# frozen_string_literal: true

module ::DiscourseHumanmark
  class Engine < ::Rails::Engine
    engine_name PLUGIN_NAME
    isolate_namespace DiscourseHumanmark
    config.autoload_paths << File.join(config.root, "lib")
  end
end
