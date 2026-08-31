class PostSerializer
  # include_author: for contexts like the Timeline where the post's author
  # isn't already implied by the URL (e.g. /users/:username/posts already
  # tells you who wrote it). Expects `post.user` to be loaded - callers
  # showing author info are expected to have eager-loaded it themselves
  # (see TimelineController), so this never triggers its own N+1 query.
  def initialize(post, include_author: false)
    @post = post
    @include_author = include_author
  end

  def as_json(*)
    json = {
      id: post.id,
      title: post.title,
      body: post.body,
      user_id: post.user_id,
      view_count: post.view_count,
      average_rating: post.average_rating.to_f,
      ratings_count: post.ratings_count,
      lock_version: post.lock_version,
      created_at: post.created_at,
      updated_at: post.updated_at
    }
    json[:author] = UserSerializer.new(post.user).as_json if include_author
    json
  end

  private

  attr_reader :post, :include_author
end
