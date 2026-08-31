# Read-only model backing the `timeline_feed` materialized view (see the
# CreateTimelineFeedView migration) - a real, independently benchmarked
# demonstration of the "materialized view for the timeline" optional
# requirement (see doc/query_analysis.md, Finding 5, and the README's
# Optional requirements section for the full reasoning). Deliberately not
# wired into TimelineController's live request path: Rails.cache already
# makes the hottest Timeline request effectively free, and the
# cursor-paginated path already performs well against posts' own index
# (Finding 1) - this exists to show the technique correctly, not because
# this app's actual access pattern needs it today.
#
# Same columns as Post (the view is `SELECT * FROM posts WHERE deleted_at
# IS NULL`), so it can carry the exact same associations/shape as far as
# PostSerializer is concerned - it just reads from a periodically
# refreshed snapshot (see RefreshTimelineFeedViewJob) instead of the live
# table.
class TimelineFeedEntry < ApplicationRecord
  self.table_name = "timeline_feed"

  # A materialized view has no real PRIMARY KEY constraint in Postgres
  # (only the plain unique index the migration adds), so ActiveRecord
  # can't infer this the way it does for an actual table - without this,
  # `find`/`find_with_ids` doesn't know what "id" means for this model.
  self.primary_key = "id"

  belongs_to :user

  # This is a view, not a table this app ever writes rows to directly -
  # the only legitimate way its data changes is a REFRESH, never an
  # INSERT/UPDATE/DELETE through ActiveRecord. Overriding readonly? (not
  # just relying on callers to remember not to save) makes that a real
  # guarantee: any accidental #save/#update on an instance raises
  # ActiveRecord::ReadOnlyRecord instead of silently attempting (and
  # failing) a write Postgres itself would reject anyway.
  def readonly?
    true
  end

  # REFRESH ... CONCURRENTLY doesn't block reads for its duration (unlike
  # a plain REFRESH, which takes an exclusive lock) - the tradeoff is that
  # it requires a unique index on the view (see the migration) and, more
  # subtly, that the view already has data at least once: Postgres refuses
  # a concurrent refresh on a view that's never been populated at all.
  # That specific case is real, not hypothetical - `pg_dump --schema-only`
  # (structure.sql, which db:test:prepare loads) always emits materialized
  # views as `WITH NO DATA` regardless of how they looked when dumped, so
  # every freshly-built test database hits it. Falling back to a plain
  # refresh exactly once self-heals that, after which CONCURRENTLY works
  # normally for every subsequent call.
  def self.refresh!
    # requires_new: true (a real SAVEPOINT, not just a plain transaction)
    # matters here even outside tests: Postgres poisons an entire
    # transaction after any failed statement inside it, so without a
    # savepoint to roll back to, a caller that happens to invoke this from
    # inside its own open transaction would find the fallback statement
    # below fails too - "current transaction is aborted" - even though
    # it's a perfectly valid statement on its own.
    ActiveRecord::Base.transaction(requires_new: true) do
      connection.execute("REFRESH MATERIALIZED VIEW CONCURRENTLY timeline_feed")
    end
  rescue ActiveRecord::StatementInvalid => e
    raise unless e.cause.is_a?(PG::FeatureNotSupported)

    connection.execute("REFRESH MATERIALIZED VIEW timeline_feed")
  end
end
