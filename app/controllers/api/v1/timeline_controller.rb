module Api
  module V1
    class TimelineController < BaseController
      include Paginatable

      # GET /api/v1/timeline?cursor=...&per_page=10
      # Public (no auth required), like the other post-reading endpoints.
      # Recent posts across *all* users - this is the actual unbounded,
      # 1M+-row, all-users case Paginatable's cursor pagination was built
      # and verified for; the per-user posts index uses the bounded/offset
      # strategy instead precisely because it's scoped to one user.
      #
      # .includes(:user) is what makes "include author information"
      # (below) not cost an extra query per post: without it, each
      # PostSerializer(..., include_author: true) call would trigger its
      # own SELECT for that post's author - classic N+1. With it, Rails
      # preloads every author in one extra query, regardless of how many
      # posts are on the page.
      #
      # Not incrementing view_count here: unlike opening a specific post
      # or a profile's post list (both explicit "look at this content"
      # actions), scrolling past a post in a feed is a weaker signal that
      # doesn't obviously belong in the same "view" definition - flagging
      # this as a deliberate choice, not an oversight, in case that's not
      # what's wanted.
      def index
        posts, meta = paginate_by_cursor(Post.kept.includes(:user))

        render json: {
          posts: posts.map { |post| PostSerializer.new(post, include_author: true).as_json },
          meta: meta
        }, status: :ok
      end
    end
  end
end
