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
        def index
          user = User.find_by(username: params[:user_username])
          scope = user ? user.posts.kept : Post.none

          posts, meta = paginate(scope.order(created_at: :desc))
          posts = posts.to_a

          # Every post on this page has the same author (`user`), so it's
          # one self-view check for the whole page, not one per post.
          Post.record_views!(posts) unless self_view?(user&.id)

          render json: { posts: posts.map { |post| PostSerializer.new(post).as_json }, meta: meta }, status: :ok
        end
      end
    end
  end
end
