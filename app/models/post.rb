class Post < ApplicationRecord
  belongs_to :user
  has_many :ratings, dependent: :destroy

  validates :title, presence: true, length: { maximum: 100 }
  validates :body, presence: true, length: { maximum: 1000 }
  validates :view_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :ratings_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :average_rating, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 5 }

  # No default_scope: soft-deleted posts should stay reachable on purpose
  # (e.g. an author viewing their own deleted posts, or an admin audit),
  # so callers opt in to `kept` explicitly rather than having it silently
  # applied everywhere and needing `unscoped` to escape it.
  scope :kept, -> { where(deleted_at: nil) }
  scope :deleted, -> { where.not(deleted_at: nil) }

  # Full-text search over title+body, ranked by relevance. `search_vector`
  # is a generated (STORED) tsvector column (see the migration) - Postgres
  # keeps it in sync with title/body on every write, so this never risks
  # searching against a stale value the way an app-maintained column
  # could. `websearch_to_tsquery` (not `plainto_tsquery`/`to_tsquery`) is
  # the one built for raw, un-sanitized user input: it tolerates stray
  # punctuation instead of raising, and still understands quoted phrases
  # and `-exclude`/`or` the way a search box is expected to.
  #
  # Ranked (not just matched) and ordered by that rank: `ts_rank` favors
  # title matches over body matches (see the migration's setweight('A')
  # vs ('B')), so a query matching a post's title outranks the same term
  # merely appearing somewhere in a long body.
  scope :search, ->(query) {
    tsquery = sanitize_sql_array([ "websearch_to_tsquery('english', ?)", query ])

    where("search_vector @@ (#{tsquery})")
      .select("posts.*, ts_rank(search_vector, #{tsquery}) AS search_rank")
      .order("search_rank DESC")
  }

  # Containment query (`@>`) against the `metadata` jsonb column: matches
  # rows whose metadata is a superset of `criteria`, e.g.
  # `Post.with_metadata("tags" => [ "ruby" ])` matches
  # `{"tags" => ["ruby", "rails"]}` but not `{"tags" => ["rails"]}`. This
  # is exactly the operator the GIN index on `metadata` (see the
  # migration) accelerates - see doc/query_analysis.md for real EXPLAIN
  # ANALYZE output confirming it's actually used, not just present.
  scope :with_metadata, ->(criteria) {
    where("metadata @> ?", criteria.to_json)
  }

  def soft_delete!
    update!(deleted_at: Time.current)
  end

  def restore!
    update!(deleted_at: nil)
  end

  def deleted?
    deleted_at.present?
  end

  # Records one or more views without writing to Postgres on the request
  # path: each view INCRs a Redis counter (ViewCounts.record) instead of
  # hitting the view_count column directly, and FlushViewCountsJob applies
  # the accumulated deltas in batches on a schedule. This used to be a
  # synchronous `UPDATE ... SET view_count = view_count + 1` per call -
  # correct, but real contention on a hot post under heavy concurrent
  # traffic, and pure write volume at 1M+ views/day either way. Moving the
  # counter into Redis removes both: the hot path no longer touches
  # Postgres at all.
  #
  # The in-memory view_count is still bumped so the *response* reflects
  # the view that just happened, even though the column itself won't
  # catch up until the next flush - a client shouldn't see their own view
  # missing just because the write is now deferred.
  def self.record_views!(posts)
    posts = Array(posts)
    return if posts.empty?

    ViewCounts.record(posts.map(&:id))
    posts.each { |post| post.view_count += 1 }
  end

  # Recomputes ratings_count/average_rating from the ratings table and
  # caches them on the post row, so reading a post (or many, for the
  # future Timeline) never has to run a live aggregate query - it costs
  # one COUNT+AVG here, on the rare write path (a user rates/re-rates a
  # post), instead of on every read.
  #
  # update_columns (not update!/save): this is derived, system-computed
  # data, not user input, so it skips validations/callbacks and writes
  # directly - the same reasoning as record_views! above. Called from
  # Rating's after_save callback, which runs inside the same implicit
  # transaction Rails already wraps every save in, so a rating and its
  # post's updated stats are already committed or rolled back together.
  #
  # with_lock (SELECT ... FOR UPDATE) closes a lost-update race: without
  # it, two concurrent ratings on the same post could each read the
  # ratings table before the other's write is committed, each compute a
  # correct-at-the-time count/average that's missing the other's rating,
  # and whichever writes last would silently overwrite the other's result
  # with an equally-incomplete one. Locking serializes that - the second
  # caller's read waits for the first to fully commit, so it always sees
  # the first's rating already reflected in its own aggregate. Rating.rate!
  # already holds this same lock for its whole transaction before this
  # ever runs, so this is usually a redundant (cheap, reentrant) re-lock -
  # it's here so this method is correct on its own regardless of caller,
  # rather than relying on every caller to remember to lock first.
  def recalculate_rating_stats!
    with_lock do
      count = ratings.count
      average = count.zero? ? 0 : ratings.average(:score)

      update_columns(ratings_count: count, average_rating: average.to_d.round(2))
    end
  end
end
