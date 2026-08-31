# This file is copied to spec/ when you run 'rails generate rspec:install'
require 'spec_helper'
ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'
# Prevent database truncation if the environment is production
abort("The Rails environment is running in production mode!") if Rails.env.production?
# Uncomment the line below in case you have `--require rails_helper` in the `.rspec` file
# that will avoid rails generators crashing because migrations haven't been run yet
# return unless Rails.env.test?
require 'rspec/rails'
# Add additional requires below this line. Rails is not loaded until this point!

# Generates doc/openapi.yaml from these same request specs - inert unless
# OPENAPI=1 is set (checked inside the gem itself), so this has no effect
# on an ordinary `bundle exec rspec` run. Regenerate with:
#   OPENAPI=1 bundle exec rspec
# CI enforces that the committed file matches what a full run produces
# (see .github/workflows/ci.yml), so an endpoint added without
# regenerating docs fails the build instead of silently drifting.
require 'rspec/openapi'

RSpec::OpenAPI.title = 'Socially Restless API'
RSpec::OpenAPI.info = {
  description: 'A RESTful API for a social media application: user accounts, posts, ratings, and an activity timeline.'
}
RSpec::OpenAPI.servers = [ { url: 'http://localhost:3000', description: 'Local development' } ]

# Every authenticated endpoint reads a bearer token via the Authorization
# header (see Api::V1::BaseController#bearer_token) - not a cookie/session,
# so it has to be opted into explicitly to show up as a documented
# parameter rather than being silently dropped.
RSpec::OpenAPI.request_headers = %w[Authorization]
RSpec::OpenAPI.security_schemes = {
  'BearerAuth' => {
    type: 'http',
    scheme: 'bearer',
    description: 'Token returned by POST /api/v1/users or POST /api/v1/session'
  }
}

# The doc-viewer routes serve this very file (HTML/YAML, not JSON), and
# documenting "GET /api-docs returns text/html" would be noise, not signal.
RSpec::OpenAPI.ignored_paths = [ %r{\A/api-docs} ]

# Requires supporting ruby files with custom matchers and macros, etc, in
# spec/support/ and its subdirectories. Files matching `spec/**/*_spec.rb` are
# run as spec files by default. This means that files in spec/support that end
# in _spec.rb will both be required and run as specs, causing the specs to be
# run twice. It is recommended that you do not name files matching this glob to
# end with _spec.rb. You can configure this pattern with the --pattern
# option on the command line or in ~/.rspec, .rspec or `.rspec-local`.
#
# The following line is provided for convenience purposes. It has the downside
# of increasing the boot-up time by auto-requiring all files in the support
# directory. Alternatively, in the individual `*_spec.rb` files, manually
# require only the support files necessary.
#
# Rails.root.glob('spec/support/**/*.rb').sort_by(&:to_s).each { |f| require f }

# Ensures that the test database schema matches the current schema file.
# If there are pending migrations it will invoke `db:test:prepare` to
# recreate the test database by loading the schema.
# If you are not using ActiveRecord, you can remove these lines.
begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end
RSpec.configure do |config|
  config.include FactoryBot::Syntax::Methods
  config.include ActiveSupport::Testing::TimeHelpers
  # Gives specs `have_enqueued_job`/`perform_enqueued_jobs`. Requires
  # explicitly swapping to the :test adapter below - just including the
  # helper module isn't enough, and without the swap `have_enqueued_job`
  # raises rather than asserting, regardless of what actually happened.
  config.include ActiveJob::TestHelper
  ActiveJob::Base.queue_adapter = :test

  # Rails.cache is a real Redis-backed store in test (see
  # config/environments/test.rb), not a null_store - so without this,
  # a cached response from one example (e.g. the Timeline endpoint) could
  # leak into a later, unrelated example expecting fresh data.
  config.before { Rails.cache.clear }

  # ViewCounts has its own dedicated Redis connection/DB index, separate
  # from Rails.cache, so clearing that doesn't touch this - pending view
  # counters need their own reset for the same reason.
  config.before { ViewCounts.redis.flushdb }

  # Sidekiq's own Redis DB, holding the recurring jobs' heartbeat claims
  # (see FlushViewCountsJob/WarmTimelineCacheJob) - without resetting it,
  # a claim made by one example could still be "active" (within its TTL)
  # when a later example expects to claim it fresh.
  config.before { Sidekiq.redis(&:flushdb) }

  # Remove this line if you're not using ActiveRecord or ActiveRecord fixtures
  config.fixture_paths = [
    Rails.root.join('spec/fixtures')
  ]

  # If you're not using ActiveRecord, or you'd prefer not to run each of your
  # examples within a transaction, remove the following line or assign false
  # instead of true.
  config.use_transactional_fixtures = true

  # You can uncomment this line to turn off ActiveRecord support entirely.
  # config.use_active_record = false

  # RSpec Rails uses metadata to mix in different behaviours to your tests,
  # for example enabling you to call `get` and `post` in request specs. e.g.:
  #
  #     RSpec.describe UsersController, type: :request do
  #       # ...
  #     end
  #
  # The different available types are documented in the features, such as in
  # https://rspec.info/features/8-0/rspec-rails
  #
  # You can also infer these behaviours automatically by location, e.g.
  # /spec/models would pull in the same behaviour as `type: :model` but this
  # behaviour is considered legacy and will be removed in a future version.
  #
  # To enable this behaviour uncomment the line below.
  # config.infer_spec_type_from_file_location!

  # Filter lines from Rails gems in backtraces.
  config.filter_rails_from_backtrace!
  # arbitrary gems may also be filtered via:
  # config.filter_gems_from_backtrace("gem name")
end

Shoulda::Matchers.configure do |config|
  config.integrate do |with|
    with.test_framework :rspec
    with.library :rails
  end
end
