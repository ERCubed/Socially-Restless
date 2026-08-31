# Periodically re-populates Rails.cache with the Timeline's default first
# page (no cursor, no min_rating filter) before it expires, so the hottest
# Timeline request - "show me the latest posts" - stays a cache hit
# instead of occasionally falling through to a live query the instant the
# 30s TTL lapses. Only that one combination is warmed: per_page/min_rating
# variations are an unbounded keyspace (see TimelineController::CACHE_EXPIRY
# comment), and none of them are anywhere near as hot as the unfiltered
# default page a client gets by just hitting the endpoint with no params.
class WarmTimelineCacheJob < ApplicationJob
  queue_as :default

  # Comfortably under TimelineController::CACHE_EXPIRY (30s) so a warmed
  # entry is always refreshed before it can expire and fall through to a
  # live query - if this ever drifted above 30s, warming would still be
  # correct, just occasionally too late to prevent a cache miss.
  INTERVAL = 25.seconds

  # Same self-perpetuating heartbeat pattern as FlushViewCountsJob - see
  # that job for the full rationale. Sidekiq's own Redis connection, not
  # Rails.cache's: Rails.cache is :null_store in development by default,
  # which has no .redis to borrow.
  HEARTBEAT_KEY = "warm_timeline_cache:heartbeat"
  HEARTBEAT_TTL = INTERVAL * 3

  def self.claim_heartbeat!
    Sidekiq.redis { |conn| conn.set(HEARTBEAT_KEY, Time.current.to_i, nx: true, ex: HEARTBEAT_TTL.to_i) }
  end

  def perform
    Sidekiq.redis { |conn| conn.expire(HEARTBEAT_KEY, HEARTBEAT_TTL.to_i) }

    cache_key = TimelineFeed.cache_key(per_page: TimelineFeed::DEFAULT_PER_PAGE, min_rating: nil)
    payload = TimelineFeed.first_page(per_page: TimelineFeed::DEFAULT_PER_PAGE, min_rating: nil)
    Rails.cache.write(cache_key, payload, expires_in: Api::V1::TimelineController::CACHE_EXPIRY)
  ensure
    self.class.set(wait: INTERVAL).perform_later unless Rails.env.test?
  end
end
