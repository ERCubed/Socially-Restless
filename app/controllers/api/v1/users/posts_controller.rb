module Api
  module V1
    module Users
      class PostsController < Api::V1::BaseController
        include Paginatable

        # GET /api/v1/users/:username/posts
        # Public (no auth required) - browsing someone's posts is not a
        # protected action. An unknown username isn't an error here: it
        # just has no posts, so this returns an empty, well-formed page
        # rather than a 404, matching how the frontend would render a
        # "no posts yet" / unknown profile the same way.
        #
        # View count: not implemented yet, but when it is, the increment
        # for each post shown here must be skipped when the viewer is the
        # post's own author (self-views shouldn't inflate the count). Since
        # this endpoint doesn't require authentication, that means
        # resolving `current_user` optimistically (present a valid bearer
        # token if given, but don't 401 without one) and comparing against
        # `user`, rather than relying on `authenticate_user!`.
        def index
          user = User.find_by(username: params[:user_username])
          scope = user ? user.posts.kept : Post.none

          posts, meta = paginate(scope.order(created_at: :desc))

          render json: { posts: posts.map { |post| PostSerializer.new(post).as_json }, meta: meta }, status: :ok
        end
      end
    end
  end
end
