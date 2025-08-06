# frozen_string_literal: true

DiscourseHumanmark::Engine.routes.draw do
  post "flows" => "api#create_flow"
end

Discourse::Application.routes.draw do
  mount DiscourseHumanmark::Engine, at: "/humanmark"
end
