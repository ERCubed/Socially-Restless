# Redis-backed pending view counters, flushed into posts.view_count in
# batches by FlushViewCountsJob instead of writing to Postgres on every
# single view. This is the design Post#record_views! (the previous,
# synchronous version) documented as its own scale-up path - closing that
# loop rather than reframing it.
#
# Own dedicated Redis connection (not Rails.cache, not Sidekiq's queue
# connection) for the same reasons as Rack::Attack and Sidekiq itself: a
# raw INCR/GETDEL round trip here needs to bypass ActiveSupport::Cache's
# local-cache layer entirely (see HealthController's comment on why that
# layer can mask things), and a plain counter has nothing to do with
# either general object caching or job queueing, so it gets its own DB
# index rather than borrowing one of theirs.
module ViewCounts
  PENDING_IDS_KEY = "view_counts:pending_ids"

  def self.redis
    @redis ||= Redis.new(url: ENV.fetch("REDIS_URL", Rails.env.test? ? "redis://localhost:6379/7" : "redis://localhost:6379/6"))
  end

  # Called on every view (one or many posts at once - e.g. a whole page of
  # a user's posts). Cheap (one pipelined Redis round trip, not a Postgres
  # write per post) and best-effort: Redis is a soft dependency everywhere
  # else in this app (see the Redis graceful-degradation work), so a view
  # getting lost during a Redis outage is an acceptable miss, not a
  # request failure - it's swallowed and logged rather than raised.
  def self.record(post_ids)
    post_ids = Array(post_ids)
    return if post_ids.empty?

    redis.pipelined do |pipeline|
      post_ids.each do |post_id|
        pipeline.incr(pending_key(post_id))
        pipeline.sadd(PENDING_IDS_KEY, post_id)
      end
    end
  rescue Redis::BaseError => e
    Rails.logger.warn("[ViewCounts] failed to record views for posts #{post_ids}: #{e.class}")
  end

  # Atomically reads and clears each pending post's counter (GETDEL, not a
  # separate GET then DEL - a view recorded between those two steps would
  # otherwise be silently lost) and returns { post_id => pending_count }
  # for FlushViewCountsJob to apply to Postgres. Only removes the post ids
  # it actually processed from the pending set, so anything SADDed while
  # this method was running stays for the next flush rather than being
  # dropped.
  def self.flush!
    post_ids = redis.smembers(PENDING_IDS_KEY).map { |id| Integer(id) }
    return {} if post_ids.empty?

    deltas = post_ids.each_with_object({}) do |post_id, result|
      count = redis.getdel(pending_key(post_id)).to_i
      result[post_id] = count if count.positive?
    end

    redis.srem(PENDING_IDS_KEY, post_ids) if post_ids.any?
    deltas
  end

  def self.pending_key(post_id)
    "view_counts:pending:#{post_id}"
  end
end
