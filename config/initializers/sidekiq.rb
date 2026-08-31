# Own dedicated Redis DB index, separate from Rails.cache (0 dev / 1 test)
# and Rack::Attack (2 dev / 3 test) - same reasoning as those: a developer
# running the app and the test suite at once shouldn't have queued jobs
# bleeding between them, and it's one less thing to guess about when
# inspecting Redis directly. In production this typically resolves to the
# same REDIS_URL as everything else, which is fine.
redis_url = ENV.fetch("REDIS_URL", Rails.env.test? ? "redis://localhost:6379/5" : "redis://localhost:6379/4")

Sidekiq.configure_client do |config|
  config.redis = { url: redis_url }
end

Sidekiq.configure_server do |config|
  config.redis = { url: redis_url }

  # Kicks off the recurring jobs' first tick when a worker process boots -
  # not on every Puma/web-process boot (this block only runs for an actual
  # `bundle exec sidekiq` process), and not once per web reload in
  # development. FlushViewCountsJob.claim_heartbeat! guards against a
  # *worker* restart starting a second concurrent chain on top of one
  # that's still alive (see that job for why).
  config.on(:startup) do
    FlushViewCountsJob.perform_later if FlushViewCountsJob.claim_heartbeat!
    WarmTimelineCacheJob.perform_later if WarmTimelineCacheJob.claim_heartbeat!
    RefreshTimelineFeedViewJob.perform_later if RefreshTimelineFeedViewJob.claim_heartbeat!
  end
end
