class Post < ApplicationRecord
  belongs_to :user

  validates :title, presence: true, length: { maximum: 100 }
  validates :body, presence: true, length: { maximum: 1000 }

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
end
