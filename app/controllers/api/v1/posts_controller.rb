module Api
  module V1
    class PostsController < BaseController
      include Paginatable

      before_action :authenticate_user!, only: [ :create, :destroy ]

      # GET /api/v1/posts?cursor=...&per_page=10
      def index
        posts, meta = paginate_by_cursor(Post.kept)

        render json: { posts: posts.map { |post| PostSerializer.new(post).as_json }, meta: meta }, status: :ok
      end

      # GET /api/v1/posts/:id
      def show
        post = Post.kept.find(params[:id])
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
