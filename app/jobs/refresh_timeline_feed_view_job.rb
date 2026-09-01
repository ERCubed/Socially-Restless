# Keeps the `timeline_feed` materialized view current (see
# TimelineFeedEntry and doc/query_analysis.md, Finding 5). Runs for real,
# on the same self-perpetuating heartbeat pattern as FlushViewCountsJob
# and WarmTimelineCacheJob (see RecurringJob) - it just isn't consulted
# by TimelineController's live request path (see that comment, and the
# README's Optional requirements section, for why).
class RefreshTimelineFeedViewJob < ApplicationJob
  include RecurringJob

  queue_as :default

  recurs_every 30.seconds

  def perform
    TimelineFeedEntry.refresh!
  end
end
