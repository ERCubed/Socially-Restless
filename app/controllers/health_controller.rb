# Deliberately separate from Rails' own /up: that one is kept lightweight
# and dependency-free on purpose, for platform-level "did the process
# boot" checks (e.g. Kamal) that get hit frequently and shouldn't pay for
# a database/Redis round trip every time. This endpoint is the opposite -
# it actually exercises the app's real dependencies and reports on each
# individually.
class HealthController < ActionController::API
  # GET /health
  def show
    checks = {
      database: check_database,
      cache: check_redis_backed_store(Rails.cache, critical: false),
      rate_limiter: check_redis_backed_store(Rack::Attack.cache.store, critical: false)
    }

    overall =
      if checks.values.any? { |check| check[:critical] && check[:status] == "error" }
        "unavailable"
      elsif checks.values.any? { |check| check[:status] == "error" }
        "degraded"
      else
        "ok"
      end

    render json: {
      status: overall,
      latest_commit: self.class.latest_commit,
      checked_at: Time.current.iso8601,
      subsystems: checks
    }, status: overall == "unavailable" ? :service_unavailable : :ok
  end

  # Which build is actually running - useful for confirming a deploy went
  # out, or that you're looking at the instance you think you are. Memoized
  # since it can't change for the life of the process.
  #
  # `.git` is excluded from the production image on purpose (see
  # .dockerignore - shipping repo history into a runtime container is
  # unnecessary bloat), so it won't exist to read there. GIT_COMMIT is the
  # escape hatch: have the deploy pipeline set it (e.g. from a Docker build
  # ARG) and this works in production too, not just dev/CI where .git is
  # actually present.
  def self.latest_commit
    @latest_commit ||= (ENV["GIT_COMMIT"].presence || read_git_head)&.slice(0, 10)
  end

  def self.read_git_head
    git_dir = Rails.root.join(".git")
    return nil unless git_dir.directory?

    head = File.read(git_dir.join("HEAD")).strip
    if head.start_with?("ref:")
      File.read(git_dir.join(head.delete_prefix("ref: "))).strip
    else
      head
    end
  rescue StandardError
    nil
  end

  private

  def check_database
    latency_ms = measure { ActiveRecord::Base.connection.execute("SELECT 1") }
    { status: "ok", critical: true, latency_ms: latency_ms }
  rescue StandardError => e
    { status: "error", critical: true, error: e.class.name }
  end

  # Soft dependency: the app is built to degrade gracefully without Redis
  # (see ActiveSupport::Cache::RedisCacheStore's failsafe wrapper), so this
  # never affects `overall` beyond "degraded".
  #
  # Pings the raw Redis connection directly rather than round-tripping a
  # value through the store's public write/read interface. That first
  # approach looked reasonable but was actually wrong: every Rails cache
  # store that supports it (including RedisCacheStore) has
  # ActiveSupport::Cache::Strategy::LocalCache prepended, and
  # ActiveSupport::Cache::Strategy::LocalCache::Middleware wraps every
  # request in a local, in-memory cache scope - so a write immediately
  # followed by a read within the same request is satisfied entirely from
  # that in-memory layer and *always* "succeeds", regardless of whether the
  # real backend is reachable at all. Confirmed the hard way: this
  # controller reported the cache healthy while Redis was verifiably down
  # (`redis-cli ping` refusing the connection) until switched to pinging
  # the raw client directly.
  #
  # `Rails.cache` in development defaults to :null_store (no Redis at all)
  # unless a developer has opted into `bin/rails dev:cache` - that's not a
  # failure, so it's reported as its own "not_configured" status rather
  # than a false "ok" (nothing was actually checked) or a false "error".
  def check_redis_backed_store(store, critical:)
    return { status: "not_configured", critical: critical } unless store.respond_to?(:redis)

    latency_ms = measure { ping(store.redis) }
    { status: "ok", critical: critical, latency_ms: latency_ms }
  rescue StandardError => e
    { status: "error", critical: critical, error: e.class.name }
  end

  def ping(redis_client)
    redis_client.is_a?(ConnectionPool) ? redis_client.with(&:ping) : redis_client.ping
  end

  def measure
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(2)
  end
end
