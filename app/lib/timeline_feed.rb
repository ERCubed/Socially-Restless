# The Timeline's "first page" logic (scope, ordering, serialization, cache
# key), extracted so TimelineController and WarmTimelineCacheJob build the
# exact same thing from one place. A job can't call
# Paginatable#paginate_by_cursor directly - that reads params/session state
# that only exists inside a request - so this exists to avoid the job and
# the controller silently drifting into two different definitions of
# "the first page" (and, worse, two different cache key formats for the
# same cached value).
module TimelineFeed
  DEFAULT_PER_PAGE = Paginatable::DEFAULT_PER_PAGE

  def self.scope(min_rating: nil)
    scope = Post.kept.includes(:user)
    scope = scope.where("average_rating >= ?", min_rating) if min_rating
    scope
  end

  # Mirrors the no-cursor branch of Paginatable#paginate_by_cursor exactly
  # (same ordering, same "fetch one extra row" has_more trick), just
  # without a cursor condition - callers of this method are always asking
  # for the very first page.
  def self.first_page(per_page: DEFAULT_PER_PAGE, min_rating: nil)
    records = scope(min_rating: min_rating)
      .order(created_at: :desc, id: :desc)
      .limit(per_page + 1)
      .to_a

    has_more = records.size > per_page
    records = records.first(per_page)
    next_cursor = has_more ? Cursor.encode(records.last.created_at, records.last.id) : nil

    {
      posts: serialize(records),
      meta: { per_page: per_page, has_more: has_more, next_cursor: next_cursor }
    }
  end

  def self.serialize(posts)
    posts.map { |post| PostSerializer.new(post, include_author: true).as_json }
  end

  def self.cache_key(per_page:, min_rating:)
    [ "timeline", "v1", per_page, min_rating ].join("/")
  end
end
