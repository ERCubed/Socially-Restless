class Rating < ApplicationRecord
  belongs_to :user
  belongs_to :post

  validates :score, presence: true, inclusion: { in: 1..5 }
  validates :user_id, uniqueness: { scope: :post_id, message: "has already rated this post" }
end
