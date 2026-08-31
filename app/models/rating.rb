class Rating < ApplicationRecord
  belongs_to :user
  belongs_to :post

  validates :score, presence: true, inclusion: { in: 1..5 }
  validates :user_id, uniqueness: { scope: :post_id, message: "has already rated this post" }

  # after_save, not after_commit: this needs to run inside the same
  # transaction as the rating write (see Post#recalculate_rating_stats!),
  # not after it, so the two stay atomic with each other.
  after_save :update_post_rating_stats

  # Creates or updates (find_or_create) a user's rating of a post, and
  # keeps that post's cached stats in sync with it, as a single atomic
  # unit: either the rating write and the stats recalculation both commit,
  # or - if either fails - neither does.
  #
  # `post.lock!` (SELECT ... FOR UPDATE) is what actually makes this safe
  # under concurrency, and it has to happen first, before find_or_initialize
  # touches `ratings` at all. Without it, two people rating the same post
  # at the same moment could each run find_or_initialize_by concurrently,
  # both see no existing row, and both attempt to INSERT - one of them
  # would hit the (user_id, post_id) unique index and blow up. Locking the
  # post serializes that: the second caller blocks until the first
  # commits, then its own find_or_initialize_by correctly sees the
  # first's now-committed row and updates it instead of colliding with it.
  # The same lock also prevents a subtler race in the stats themselves -
  # see Post#recalculate_rating_stats! - so one lock, taken once, covers
  # both problems.
  def self.rate!(user:, post:, score:)
    transaction do
      post.lock!

      rating = find_or_initialize_by(user: user, post: post)
      rating.score = score
      rating.save!
      rating
    end
  end

  private

  def update_post_rating_stats
    post.recalculate_rating_stats!
  end
end
