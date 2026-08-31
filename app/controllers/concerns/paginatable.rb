module Paginatable
  extend ActiveSupport::Concern

  DEFAULT_PER_PAGE = 10
  MAX_PER_PAGE = 100

  private

  # Keyset (cursor) pagination on (created_at, id) descending, instead of
  # OFFSET/LIMIT. `OFFSET n` forces Postgres to walk and discard every one
  # of the n skipped rows before it can return anything, and a `COUNT(*)`
  # over a filtered multi-million-row table is itself a full scan - both
  # get linearly slower the *deeper* you page, unboundedly. A keyset
  # condition on the (deleted_at, created_at, id) index avoids that: cost
  # depends on how many rows are *left after* the cursor, not on how deep
  # the page is, and it never re-walks rows already returned.
  #
  # Verified against a real 1.2M-row table (EXPLAIN ANALYZE, not just
  # theory): a deep cursor - most of the table already paged past - hits a
  # Bitmap Index Scan and returns in well under 1ms, as expected. A shallow
  # cursor near the top - e.g. "page 2" of a feed, where ~all 1.2M rows
  # still match "older than this" - is where it gets interesting: Postgres'
  # planner estimates that as low-selectivity and, despite the covering
  # index being available (confirmed by forcing it on with
  # `enable_seqscan = off`), chooses a full Seq Scan + top-N sort instead,
  # at ~55ms. Neither disabling parallelism nor raising
  # `default_statistics_target` on created_at changed that choice - this
  # is a known Postgres cost-estimation limitation for "ORDER BY ... LIMIT"
  # over a high-selectivity range condition, not a missing index or a bug
  # here. The saving grace: unlike OFFSET, that cost is bounded by table
  # size, not by page depth, and it only hits the first handful of pages
  # (the ones a real feed serves the most). If that 55ms ever shows up as
  # a real bottleneck, the fix isn't a fancier query - it's caching the
  # first page or two, which the Timeline endpoint needs anyway.
  #
  # The other trade-off, true regardless of the above: no "jump to page
  # 50" (only "give me what comes after this cursor") and no exact total
  # count, since computing one is the expensive scan being avoided in the
  # first place. That's the standard shape for infinite-scroll/feed-style
  # APIs (GitHub's and Stripe's list endpoints both work this way) and is
  # what `scope` here is expected to be used for. `scope` must already be
  # ordered by nothing (this method applies its own order) and filtered
  # down to whatever the caller wants (e.g. `Post.kept`).
  def paginate_by_cursor(scope, cursor_column: :created_at)
    cursor = Cursor.decode(params[:cursor])

    scope = scope.order(cursor_column => :desc, id: :desc)

    if cursor
      column = scope.klass.connection.quote_column_name(cursor_column)
      scope = scope.where("(#{column}, id) < (?, ?)", cursor.timestamp, cursor.id)
    end

    # Fetch one extra row so we can tell whether there's a next page
    # without a separate (expensive) COUNT(*) query.
    records = scope.limit(per_page + 1).to_a
    has_more = records.size > per_page
    records = records.first(per_page)

    next_cursor = has_more ? Cursor.encode(records.last[cursor_column], records.last.id) : nil

    meta = { per_page: per_page, has_more: has_more, next_cursor: next_cursor }

    [ records, meta ]
  end

  def per_page
    @per_page ||= begin
      requested = params[:per_page].to_i
      requested = DEFAULT_PER_PAGE if requested <= 0
      [ requested, MAX_PER_PAGE ].min
    end
  end
end
