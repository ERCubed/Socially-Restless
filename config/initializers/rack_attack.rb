# Rack::Attack.cache.store defaults to Rails.cache, which is :null_store in
# both development and test by default (see config/environments) - that
# would make every throttle below silently do nothing. Using a dedicated
# MemoryStore decouples rate-limit counters from the app's general
# object-cache configuration.
#
# This only counts requests seen by *this* process: fine for a single
# server, but each app server/worker in a multi-process/multi-server
# deployment would keep its own counters, effectively multiplying the
# limits by the number of processes. The fix there is a shared store -
# point this at Redis instead, the same upgrade the optional Redis-based
# concurrency work would bring into the stack anyway.
Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new

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
