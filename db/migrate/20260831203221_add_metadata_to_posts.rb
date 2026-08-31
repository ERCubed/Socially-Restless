class AddMetadataToPosts < ActiveRecord::Migration[8.1]
  def change
    # jsonb, not json: jsonb stores a decomposed binary format (slightly
    # slower to write, since it has to be parsed and re-encoded on
    # insert), which is what makes it indexable and queryable at all - a
    # plain json column stores the exact input text and can only ever be
    # queried by re-parsing it on every row, with no index support. Free-
    # form metadata (tags, client info, feature flags on a post) is
    # exactly what jsonb is for: an attribute that varies per row and
    # doesn't earn its own column, without giving up indexed querying.
    add_column :posts, :metadata, :jsonb, null: false, default: {}

    # GIN (Generalized Inverted iNdex), not the default btree - btree
    # can't index jsonb's containment operator (`@>`) at all. GIN builds
    # an inverted index over every key/value pair (and array element)
    # inside the column, so "does this post's metadata contain
    # {tags: ['ruby']}" becomes an index lookup instead of a per-row scan
    # that has to parse and inspect the JSON of every post.
    add_index :posts, :metadata, using: :gin
  end
end
