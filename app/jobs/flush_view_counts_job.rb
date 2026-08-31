# Periodically applies ViewCounts' accumulated Redis counters to
# posts.view_count in one batched UPDATE, instead of the request path
# writing to Postgres on every view (see Post.record_views!).
class FlushViewCountsJob < ApplicationJob
  queue_as :default

  # How often this re-enqueues itself (see #perform). Frequent enough that
  # view_count doesn't look stale for long; infrequent enough to be a real
  # batching win over writing to Postgres on every view.
  INTERVAL = 30.seconds

  # A heartbeat key (not a plain boolean flag) - refreshed on every tick,
  # not just set once - so exactly one self-perpetuating chain is ever
  # active. Self-perpetuating jobs don't survive their own loss (if a tick
  # is dropped without retrying, e.g. the worker is killed mid-job, the
  # chain just stops), so left alone, every worker restart would start a
  # duplicate chain on top of whatever's still running from before. The
  # TTL comfortably outlives one interval, so a chain that's still alive
  # keeps renewing its own claim before it can expire, and a new chain
  # only starts (see config/initializers/sidekiq.rb) once the old one has
  # genuinely gone quiet.
  HEARTBEAT_KEY = "flush_view_counts:heartbeat"
  HEARTBEAT_TTL = INTERVAL * 3

  # Sidekiq's own Redis connection, not ViewCounts' (or Rails.cache's, for
  # WarmTimelineCacheJob's identical pattern) - the heartbeat is about
  # managing the recurring job itself, which is queue infrastructure, not
  # a view-counting or caching concern, and borrowing either of those
  # connections for it would be the wrong ownership. It also sidesteps a
  # real problem for the cache-warming job specifically: Rails.cache is
  # :null_store in development by default, which has no .redis to use.
  def self.claim_heartbeat!
    Sidekiq.redis { |conn| conn.set(HEARTBEAT_KEY, Time.current.to_i, nx: true, ex: HEARTBEAT_TTL.to_i) }
  end

  def perform
    Sidekiq.redis { |conn| conn.expire(HEARTBEAT_KEY, HEARTBEAT_TTL.to_i) }

    deltas = ViewCounts.flush!
    apply_to_postgres!(deltas) if deltas.any?
  ensure
    # Not sidekiq-cron/sidekiq-scheduler: one fewer gem for a single
    # recurring job. The tradeoff is the one described above, mitigated
    # but not eliminated by the heartbeat.
    self.class.set(wait: INTERVAL).perform_later unless Rails.env.test?
  end

  private

  # Raw SQL, not N calls to Post#record_views!: one round trip regardless
  # of how many posts have pending views, which is the entire point of
  # batching them in the first place. Every id/delta is bound (`?`), not
  # interpolated, via sanitize_sql_array - the WHEN/id-list *shape* of the
  # query is built from the deltas hash, but no value from it ever reaches
  # the SQL string directly.
  def apply_to_postgres!(deltas)
    when_sql = deltas.map { "WHEN ? THEN view_count + ?" }.join(" ")
    ids_sql = deltas.map { "?" }.join(",")
    bind_values = deltas.flat_map { |id, delta| [ id, delta ] } + deltas.keys

    sql = Post.sanitize_sql_array(
      [ "UPDATE posts SET view_count = CASE id #{when_sql} END WHERE id IN (#{ids_sql})", *bind_values ]
    )
    Post.connection.execute(sql)
  end
end
