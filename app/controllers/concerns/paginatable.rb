module Paginatable
  extend ActiveSupport::Concern

  DEFAULT_PER_PAGE = 10
  MAX_PER_PAGE = 100

  private

  # Offset pagination: page/per_page, with an exact total_count/total_pages.
  # Good fit for a *bounded* dataset, like one user's own posts - a profile
  # page benefits from "jump to page 3" more than it suffers from OFFSET's
  # cost growing with page depth, since no single user is realistically
  # paging deep into hundreds of thousands of their own posts. Contrast
  # with `paginate_by_cursor` below, which is for the opposite case: an
  # unbounded, all-users feed where deep paging and 1M+ rows are the norm.
  def paginate(scope)
    # unscope(:select, :order): a plain `SELECT COUNT(*) ... WHERE ...`
    # regardless of what the scope's own select/order look like - needed
    # for callers like Post.search, whose select includes a computed
    # `ts_rank(...) AS search_rank` column that Postgres can't combine
    # with an aggregate COUNT(*) in the same query.
    total_count = scope.unscope(:select, :order).count
    total_pages = (total_count / per_page.to_f).ceil

    records = scope.offset((page - 1) * per_page).limit(per_page)

    meta = {
      page: page,
      per_page: per_page,
      total_count: total_count,
      total_pages: total_pages
    }

    [ records, meta ]
  end

  def page
    @page ||= [ params[:page].to_i, 1 ].max
  end

  # Not yet wired up to a route - reserved for the Activity Timeline
  # endpoint (recent posts across *all* users), which is the actual
  # unbounded, 1M+-row case this was built and verified for. Keyset
  # (cursor) pagination on (created_at, id) descending, instead of
  # OFFSET/LIMIT. `OFFSET n` forces Postgres to walk and discard every one
  # of the n skipped rows before it can return anything, and a `COUNT(*)`
  # over a filtered multi-million-row table is itself a full scan - both
  # get linearly slower the *deeper* you page, unboundedly. A keyset
  # condition on the (deleted_at, created_at, id) index avoids that: cost
  # depends on how many rows are *left after* the cursor, not on how deep
  # the page is, and it never re-walks rows already returned.
  #
  # Verified against a real 1.2M-row table (EXPLAIN ANALYZE, not just
  # theory - see doc/query_analysis.md for full captured output and a
  # four-point selectivity table): cost here tracks *selectivity* (how many
  # rows are left after the cursor), not literally page depth. A deep
  # cursor - under ~2% of the table remaining - hits a Bitmap Index Scan on
  # the (deleted_at, created_at, id) index and returns in single-digit ms.
  # A shallow cursor near the top - e.g. "page 2" of a feed, where most of
  # the table still matches "older than this" - falls back to a Seq Scan +
  # top-N sort instead, at up to ~150ms for the unfiltered first page.
  # Forcing the index on with `enable_seqscan = off` at that selectivity
  # made the query slower (250ms, not faster) - so this isn't a planner
  # limitation being routed around, it's the planner making the right call:
  # past a certain fraction of the table, a sequential scan really does
  # beat scattered index lookups. The saving grace is unchanged either way:
  # unlike OFFSET, that cost is bounded by table size, not by page depth,
  # and it only hits the first handful of pages (the ones a real feed
  # serves the most) - which is exactly the page Timeline's cache already
  # targets (see WarmTimelineCacheJob), so real users essentially never pay
  # for it.
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
