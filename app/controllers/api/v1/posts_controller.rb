module Api
  module V1
    class PostsController < BaseController
      before_action :authenticate_user!, only: [ :create, :destroy ]

      # GET /api/v1/posts/:id
      def show
        post = Post.kept.find(params[:id])
        Post.record_views!([ post ]) unless self_view?(post.user_id)
        render json: { post: PostSerializer.new(post).as_json }, status: :ok
      end

      # POST /api/v1/posts
      def create
        post = current_user.posts.new(post_params)

        if post.save
          render json: { post: PostSerializer.new(post).as_json }, status: :created
        else
          render_error(message: "Validation failed", status: :unprocessable_content, details: post.errors.full_messages)
        end
      end

      # DELETE /api/v1/posts/:id
      # Soft delete: only the owner can delete their own post, and only if
      # it isn't already deleted (an already-deleted or nonexistent id both
      # 404, so this doesn't leak which case it was).
      def destroy
        post = current_user.posts.kept.find(params[:id])
        post.soft_delete!
        head :no_content
      end

      private

      # user_id is intentionally not permitted here: a post's author is
      # always the authenticated user, never a client-supplied value.
      def post_params
        params.require(:post).permit(:title, :body)
      end
    end
  end
end
