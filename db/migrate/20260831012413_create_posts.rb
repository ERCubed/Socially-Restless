class CreatePosts < ActiveRecord::Migration[8.1]
  def change
    create_table :posts do |t|
      t.references :user, null: false, foreign_key: true
      t.string :title, limit: 100, null: false
      t.string :body, limit: 1000, null: false
      t.datetime :deleted_at
      t.integer :view_count, null: false, default: 0

      t.timestamps
    end

    # Composite rather than a standalone `created_at` index: almost every
    # read will filter out soft-deleted rows and sort by recency together,
    # and Postgres can satisfy "WHERE deleted_at IS NULL ORDER BY created_at"
    # from this single index instead of two separate ones. `id` is included
    # as a tiebreaker for keyset (cursor) pagination: paging by created_at
    # alone would misbehave if two rows ever share a timestamp, since
    # "WHERE (created_at, id) < (?, ?) ORDER BY created_at DESC, id DESC"
    # needs id in both the sort and the index to stay a pure index scan.
    add_index :posts, [ :deleted_at, :created_at, :id ]
  end
end
