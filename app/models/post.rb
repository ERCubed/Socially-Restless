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

  def soft_delete!
    update!(deleted_at: Time.current)
  end

  def restore!
    update!(deleted_at: nil)
  end

  def deleted?
    deleted_at.present?
  end

  # Bumps view_count for one or more posts in a single atomic UPDATE
  # (`SET view_count = view_count + 1`, not a Ruby read-modify-write), so
  # concurrent viewers of the same post can't clobber each other's
  # increment. Callers pass already-loaded Post instances and get their
  # in-memory view_count kept in sync with the DB write, without a second
  # SELECT round trip.
  #
  # This still costs a synchronous write on the request path for every
  # view, which is fine at this scale but becomes real contention on a hot
  # post under heavy concurrent traffic (many requests all trying to lock
  # and update the same row) or just adds up as pure write volume at 1M+
  # views/day. The scale-up path if that shows up: stop writing to
  # Postgres per-request and instead INCR a Redis counter per post,
  # enqueue (Sidekiq) periodic/batched flushes of those counters into
  # view_count, and read the Redis value (falling back to the column) for
  # any view_count shown back to a client before the next flush.
  def self.record_views!(posts)
    ids = posts.map(&:id)
    return if ids.empty?

    where(id: ids).update_all("view_count = view_count + 1")
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
