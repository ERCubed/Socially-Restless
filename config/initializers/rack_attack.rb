# Rack::Attack.cache.store defaults to Rails.cache - deliberately not used
# here, because Rails.cache is a :null_store in development unless a
# developer has opted in via `bin/rails dev:cache` (see
# config/environments/development.rb). Rate limiting is a security
# control, not a performance nicety, so it shouldn't quietly stop working
# just because that unrelated toggle is off. This gets its own Redis
# connection instead, always active independent of that toggle. In local
# dev/test it defaults to its own DB index (2 dev, 3 test), distinct from
# Rails.cache's (0 dev, 1 test) and from each other - so a developer
# running the app locally can't have their rate-limit counters bleed into
# a concurrently-running test suite, or vice versa. In production both
# typically resolve to the same REDIS_URL, which is fine since rack-attack
# namespaces its keys under "rack::attack:".
#
# Using :redis_cache_store (not a raw Redis client) also means this
# degrades gracefully if Redis is unavailable: every read/write in
# ActiveSupport::Cache::RedisCacheStore is wrapped in a rescue that logs
# the error and returns a safe fallback instead of raising - so a Redis
# outage disables throttling (fails open) rather than 500ing every
# request. Confirmed straight from Rails' source
# (ActiveSupport::Cache::RedisCacheStore#failsafe), not assumed.
#
# Shared across app server processes, unlike an in-memory store: every
# process counts against the same Redis-backed counters, so the limits
# below are enforced correctly across a whole fleet, not per-process.
default_local_redis_url = Rails.env.test? ? "redis://localhost:6379/3" : "redis://localhost:6379/2"
Rack::Attack.cache.store = ActiveSupport::Cache::RedisCacheStore.new(
  url: ENV.fetch("REDIS_URL", default_local_redis_url)
)

# Blanket protection against abuse/scraping across the whole API.
Rack::Attack.throttle("api/ip", limit: 300, period: 5.minutes) do |request|
  request.ip if request.path.start_with?("/api/")
end

# Login and signup are classic brute-force / credential-stuffing / spam-
# signup targets, so they get a much tighter limit than general traffic.
Rack::Attack.throttle("login/ip", limit: 5, period: 20.seconds) do |request|
  request.ip if request.post? && request.path == "/api/v1/session"
end

Rack::Attack.throttle("signup/ip", limit: 5, period: 1.minute) do |request|
  request.ip if request.post? && request.path == "/api/v1/users"
end

# Matches the API's shared error envelope ({ error: { message, details } })
# instead of rack-attack's default plain-text body, so a throttled request
# looks like every other error this API returns rather than a one-off.
Rack::Attack.throttled_responder = lambda do |request|
  match_data = request.env["rack.attack.match_data"]
  now = match_data[:epoch_time]
  retry_after = match_data[:period] - (now % match_data[:period])

  headers = {
    "Content-Type" => "application/json",
    "Retry-After" => retry_after.to_s
  }
  body = { error: { message: "Rate limit exceeded. Try again later.", details: [] } }.to_json

  [ 429, headers, [ body ] ]
end
