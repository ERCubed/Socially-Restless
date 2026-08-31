class CreateTimelineFeedView < ActiveRecord::Migration[8.1]
  # Not wired into the live Timeline request path (see doc/query_analysis.md
  # and README's Optional requirements section for the full reasoning) -
  # this exists as a real, working, independently benchmarked
  # demonstration of the technique. Rails.cache already makes the
  # hottest Timeline request (the cached first page) effectively free,
  # and the cursor-paginated path already performs well against the
  # existing (deleted_at, created_at, id) index (see Finding 1) - a
  # materialized view's real value here is showing the technique
  # correctly, not fixing a bottleneck this app actually has.
  def up
    execute <<~SQL
      CREATE MATERIALIZED VIEW timeline_feed AS
      SELECT * FROM posts WHERE deleted_at IS NULL
      WITH DATA;
    SQL

    # A unique index is required for REFRESH ... CONCURRENTLY (see
    # RefreshTimelineFeedViewJob) - without one, Postgres can only do a
    # full-table-locking refresh that blocks reads for its duration.
    execute "CREATE UNIQUE INDEX index_timeline_feed_on_id ON timeline_feed (id);"

    # Mirrors the covering index posts itself has for this access
    # pattern - deleted_at is omitted here since every row in the view
    # already satisfies deleted_at IS NULL by construction.
    execute "CREATE INDEX index_timeline_feed_on_created_at_and_id ON timeline_feed (created_at, id);"
  end

  def down
    execute "DROP MATERIALIZED VIEW IF EXISTS timeline_feed;"
  end
end
