require_relative "boot"

require "rails"

# Pick the frameworks you want, instead of require "rails/all". This app has
# no use for Action Mailer (and Action Mailbox/Action Text, which depend on
# it), Active Storage, Action Cable, or Minitest (we test with RSpec), so
# they're left out entirely rather than just left unconfigured.
%w[
  active_record/railtie
  action_controller/railtie
  action_view/railtie
  active_job/railtie
].each do |railtie|
  require railtie
end

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module SociallyRestless
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.eager_load_paths << Rails.root.join("extras")

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = true

    # We always store and reason about timestamps in UTC (these already
    # match Rails' own defaults; set explicitly so that doesn't silently
    # change). Clients may send timestamps in any offset they like -
    # `time_zone_aware_attributes` parses those via `Time.zone.parse` and
    # normalizes to UTC before the value ever reaches ActiveRecord.
    config.time_zone = "UTC"
    config.active_record.default_timezone = :utc
    config.active_record.time_zone_aware_attributes = true

    # See config/initializers/sidekiq.rb for the Redis connection this
    # queues into.
    config.active_job.queue_adapter = :sidekiq
  end
end
