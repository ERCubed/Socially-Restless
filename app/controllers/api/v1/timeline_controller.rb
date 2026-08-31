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
      # Caching strategy: only the first page (no cursor) is cached. That's
      # deliberate, not partial - the overwhelming majority of Timeline
      # traffic is "show me the latest posts" (no cursor), so caching just
      # that turns the hottest, most-repeated query into a cache hit with a
      # small, bounded keyspace (one entry per distinct per_page/min_rating
      # combination actually in use). Caching every cursor value too would
      # explode that keyspace with mostly single-use entries - poor hit
      # rate for little benefit, since a cursor page is inherently more
      # varied and less repeated than "page one."
      #
      # A flat 30s expiry (not active invalidation on post/rating writes)
      # is the "basic" half of this: the timeline can be up to 30s stale,
      # which is an ordinary, accepted tradeoff for a social feed - nobody
      # expects a new post or rating to be reflected within milliseconds -
      # and it avoids coupling Post/Rating write paths to Timeline's cache
      # keys. Actively busting the cache on every write would keep it
      # perfectly fresh but adds real complexity for a benefit most feeds
      # don't need; worth revisiting if 30s turns out to be too stale for
      # real usage.
      CACHE_EXPIRY = 30.seconds

      def index
        if params[:cursor].present?
          render json: timeline_payload, status: :ok
        else
          cache_key = TimelineFeed.cache_key(per_page: per_page, min_rating: min_rating)
          render json: Rails.cache.fetch(cache_key, expires_in: CACHE_EXPIRY) {
            TimelineFeed.first_page(per_page: per_page, min_rating: min_rating)
          }, status: :ok
        end
      end

      private

      def timeline_payload
        posts, meta = paginate_by_cursor(TimelineFeed.scope(min_rating: min_rating))

        { posts: TimelineFeed.serialize(posts), meta: meta }
      end

      # Blank/missing/non-numeric all mean "no filter", same graceful
      # handling as page/per_page elsewhere - a garbage value degrades to
      # "show everything" rather than erroring.
      def min_rating
        params[:min_rating].presence&.to_f
      end
    end
  end
end
