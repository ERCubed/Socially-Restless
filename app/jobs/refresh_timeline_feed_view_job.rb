# Keeps the `timeline_feed` materialized view current (see
# TimelineFeedEntry and doc/query_analysis.md, Finding 5). Runs for real,
# on the same self-perpetuating heartbeat pattern as FlushViewCountsJob
# and WarmTimelineCacheJob - it just isn't consulted by
# TimelineController's live request path (see that comment, and the
# README's Optional requirements section, for why).
class RefreshTimelineFeedViewJob < ApplicationJob
  queue_as :default

  INTERVAL = 30.seconds
  HEARTBEAT_KEY = "refresh_timeline_feed_view:heartbeat"
  HEARTBEAT_TTL = INTERVAL * 3

  def self.claim_heartbeat!
    Sidekiq.redis { |conn| conn.set(HEARTBEAT_KEY, Time.current.to_i, nx: true, ex: HEARTBEAT_TTL.to_i) }
  end

  def perform
    Sidekiq.redis { |conn| conn.expire(HEARTBEAT_KEY, HEARTBEAT_TTL.to_i) }

    TimelineFeedEntry.refresh!
  ensure
    self.class.set(wait: INTERVAL).perform_later unless Rails.env.test?
  end
end
