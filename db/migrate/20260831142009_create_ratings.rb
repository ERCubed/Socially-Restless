class CreateRatings < ActiveRecord::Migration[8.1]
  def change
    create_table :ratings do |t|
      t.references :user, null: false, foreign_key: true
      t.references :post, null: false, foreign_key: true
      t.integer :score, null: false

      t.timestamps
    end

    # Enforces "one rating per user per post" at the DB level, not just via
    # a Rails uniqueness validation (which can't stop two concurrent
    # requests from both passing the check before either has inserted).
    # This index also serves as the lookup path for find_or_initialize_by
    # (user, post), so it isn't purely defensive.
    add_index :ratings, [ :user_id, :post_id ], unique: true

    add_check_constraint :ratings, "score BETWEEN 1 AND 5", name: "ratings_score_range_check"
  end
end
