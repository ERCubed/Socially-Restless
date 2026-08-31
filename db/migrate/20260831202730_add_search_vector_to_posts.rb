class AddSearchVectorToPosts < ActiveRecord::Migration[8.1]
  def change
    # A generated (STORED) column, not a callback that recomputes on save:
    # Postgres itself keeps this in sync with title/body on every insert
    # and update, so it can never drift the way an app-level "recompute
    # and save the search vector" callback could if a caller ever bypassed
    # it (bulk update_all, a data migration, etc). setweight'ing title
    # higher than body ('A' outranks 'B' in ts_rank) means a match in the
    # title ranks above the same term only appearing in the body.
    add_column :posts, :search_vector, :virtual,
      type: :tsvector,
      as: "setweight(to_tsvector('english', title), 'A') || setweight(to_tsvector('english', body), 'B')",
      stored: true

    add_index :posts, :search_vector, using: :gin
  end
end
