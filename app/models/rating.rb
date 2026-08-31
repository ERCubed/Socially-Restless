class Rating < ApplicationRecord
  belongs_to :user
  belongs_to :post

  validates :score, presence: true, inclusion: { in: 1..5 }
  validates :user_id, uniqueness: { scope: :post_id, message: "has already rated this post" }

  # after_save, not after_commit: this needs to run inside the same
  # transaction as the rating write (see Post#recalculate_rating_stats!),
  # not after it, so the two stay atomic with each other.
  after_save :update_post_rating_stats

  private

  def update_post_rating_stats
    post.recalculate_rating_stats!
  end
end
