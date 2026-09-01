# Shared scaffolding for a self-perpetuating recurring job (see
# FlushViewCountsJob, WarmTimelineCacheJob, RefreshTimelineFeedViewJob) -
# not sidekiq-cron/sidekiq-scheduler: one fewer gem for a handful of
# recurring jobs. The tradeoff: a self-perpetuating chain doesn't survive
# its own loss (if a tick is dropped without retrying, e.g. the worker is
# killed mid-job, the chain just stops), so left alone, every worker
# restart would start a duplicate chain on top of whatever's still
# running from before.
#
# The fix is a heartbeat key (not a plain boolean flag) - refreshed on
# every tick, not just set once - so exactly one chain is ever active.
# The TTL comfortably outlives one interval, so a chain that's still
# alive keeps renewing its own claim before it can expire, and a new
# chain only starts (see config/initializers/sidekiq.rb's `on(:startup)`
# hook) once the old one has genuinely gone quiet.
#
# Sidekiq's own Redis connection, not ViewCounts'/Rails.cache's: the
# heartbeat is about managing the recurring job itself, which is queue
# infrastructure, not a view-counting or caching concern, and borrowing
# either of those connections for it would be the wrong ownership. It
# also sidesteps a real problem for cache/view-related jobs specifically:
# Rails.cache is :null_store in development by default, which has no
# .redis to use at all.
#
# Usage: `include RecurringJob` and declare `recurs_every <duration>` -
# `perform` only needs to implement the job's actual work; the heartbeat
# refresh and self-rescheduling happen around it automatically.
module RecurringJob
  extend ActiveSupport::Concern

  included do
    class_attribute :interval, instance_writer: false

    around_perform do |job, block|
      Sidekiq.redis { |conn| conn.expire(job.class.heartbeat_key, job.class.heartbeat_ttl) }
      block.call
    ensure
      job.class.set(wait: job.class.interval).perform_later unless Rails.env.test?
    end
  end

  class_methods do
    def recurs_every(interval)
      self.interval = interval
    end

    def heartbeat_key
      "#{name.underscore}:heartbeat"
    end

    # TTL comfortably outlives one interval (3x) - see the module comment.
    # Sidekiq's Redis client (redis-client, not the `redis` gem) rejects
    # ActiveSupport::Duration for `ex:`/`expire` - it needs a plain
    # integer - hence `.to_i`.
    def heartbeat_ttl
      (interval * 3).to_i
    end

    def claim_heartbeat!
      Sidekiq.redis { |conn| conn.set(heartbeat_key, Time.current.to_i, nx: true, ex: heartbeat_ttl) }
    end
  end
end
