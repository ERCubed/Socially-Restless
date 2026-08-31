class Post < ApplicationRecord
  belongs_to :user

  validates :title, presence: true, length: { maximum: 100 }
  validates :body, presence: true, length: { maximum: 1000 }
  validates :view_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

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
end
