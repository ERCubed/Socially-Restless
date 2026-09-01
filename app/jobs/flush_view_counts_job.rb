# Periodically applies ViewCounts' accumulated Redis counters to
# posts.view_count in one batched UPDATE, instead of the request path
# writing to Postgres on every view (see Post.record_views!). See
# RecurringJob for the self-perpetuating/heartbeat scaffolding this
# builds on.
class FlushViewCountsJob < ApplicationJob
  include RecurringJob

  queue_as :default

  # How often this re-enqueues itself. Frequent enough that view_count
  # doesn't look stale for long; infrequent enough to be a real batching
  # win over writing to Postgres on every view.
  recurs_every 30.seconds

  def perform
    deltas = ViewCounts.flush!
    apply_to_postgres!(deltas) if deltas.any?
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
