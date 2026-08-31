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
      #
      # ?min_rating=4 filters to posts with average_rating >= 4. There's
      # no index covering average_rating, so at 1M+ rows this filter adds
      # a per-row check Postgres can't skip via an index the way the
      # deleted_at/created_at/id keyset condition can - same category of
      # cost as the "shallow cursor page" planner behavior documented on
      # Paginatable#paginate_by_cursor, just triggered by a different
      # condition. Not worth a dedicated index for a filter that doesn't
      # exist as a real access pattern yet; worth revisiting (a composite
      # index, or a precomputed "highly-rated" view) if it turns out to be
      # a heavily-used one.
      def index
        scope = Post.kept.includes(:user)
        scope = scope.where("average_rating >= ?", min_rating) if min_rating

        posts, meta = paginate_by_cursor(scope)

        render json: {
          posts: posts.map { |post| PostSerializer.new(post, include_author: true).as_json },
          meta: meta
        }, status: :ok
      end

      private

      # Blank/missing/non-numeric all mean "no filter", same graceful
      # handling as page/per_page elsewhere - a garbage value degrades to
      # "show everything" rather than erroring.
      def min_rating
        params[:min_rating].presence&.to_f
      end
    end
  end
end
