class AddRatingStatsToPosts < ActiveRecord::Migration[8.1]
  def change
    # Cached aggregates, recomputed from `ratings` on every rating write
    # (see Post#recalculate_rating_stats!) so that reading a post - or many
    # posts at once, as the Activity Timeline will - never has to run a
    # live AVG()/COUNT() over the ratings table.
    add_column :posts, :ratings_count, :integer, null: false, default: 0
    # precision: 3, scale: 2 covers 0.00..5.00 (and, harmlessly, up to
    # 9.99) with two decimal places of resolution - enough to distinguish
    # ratings without implying false precision.
    add_column :posts, :average_rating, :decimal, precision: 3, scale: 2, null: false, default: "0.0"

    add_check_constraint :posts, "ratings_count >= 0", name: "posts_ratings_count_range_check"
    add_check_constraint :posts, "average_rating >= 0 AND average_rating <= 5", name: "posts_average_rating_range_check"
  end
end
