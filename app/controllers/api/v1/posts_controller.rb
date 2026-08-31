module Api
  module V1
    class PostsController < BaseController
      include Paginatable

      before_action :authenticate_user!, only: [ :create, :update, :destroy ]

      # GET /api/v1/posts/search?q=...
      # Public, like the other post-reading endpoints. Offset pagination
      # (not cursor, unlike Timeline): a text search's result set is
      # bounded by how many posts actually match the query, not "every
      # post ever made" - the unbounded-depth problem cursor pagination
      # exists for doesn't apply here the way it does for the Timeline.
      #
      # Not incrementing view_count: same reasoning as Timeline - seeing a
      # post in a list of search results is a weaker signal than opening
      # it, and this endpoint (like Timeline) shows results across every
      # user, so include_author matches Timeline's serialization shape.
      def search
        query = params[:q].presence
        raise ActionController::ParameterMissing, :q if query.blank?

        posts, meta = paginate(Post.kept.search(query))

        render json: {
          posts: posts.map { |post| PostSerializer.new(post, include_author: true).as_json },
          meta: meta
        }, status: :ok
      end

      # GET /api/v1/posts/:id
      def show
        post = Post.kept.find(params[:id])
        Post.record_views!([ post ]) unless self_view?(post.user_id)
        render json: { post: PostSerializer.new(post).as_json }, status: :ok
      end

      # POST /api/v1/posts
      def create
        post = current_user.posts.new(create_params)

        if post.save
          render json: { post: PostSerializer.new(post).as_json }, status: :created
        else
          render_error(message: "Validation failed", status: :unprocessable_content, details: post.errors.full_messages)
        end
      end

      # PATCH/PUT /api/v1/posts/:id
      # Optimistic (posts.lock_version - ActiveRecord's built-in mechanism,
      # no gem needed), not pessimistic like the rating writes: two people
      # editing the same post is a rare, non-blocking case, unlike rating
      # recalculation which happens on every write and genuinely needs to
      # serialize. It's cheaper to let concurrent edits proceed and only
      # reject the second one if it actually collides, than to make every
      # edit wait on a lock regardless of whether a conflict was ever going
      # to happen.
      #
      # The client must send back the lock_version it last saw (from a
      # prior GET), not just title/body - without that, the record `find`
      # just loaded already carries the *current* lock_version, so any
      # update would trivially match it. The client stating "this is the
      # version I edited from" is what makes the check mean anything.
      # ActiveRecord::StaleObjectError (version mismatch -> 409) is handled
      # globally in ApplicationController.
      def update
        post = current_user.posts.kept.find(params[:id])
        raise ActionController::ParameterMissing, :lock_version if params.dig(:post, :lock_version).blank?

        post.update!(update_params)
        render json: { post: PostSerializer.new(post).as_json }, status: :ok
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
      def create_params
        permit_metadata(params.require(:post).permit(:title, :body))
      end

      # lock_version is permitted here, unlike create: it's not something
      # a client is trying to change, it's the version they're proving
      # they last read (see #update above) - required, not just permitted,
      # via the explicit presence check in #update.
      def update_params
        permit_metadata(params.require(:post).permit(:title, :body, :lock_version))
      end

      # metadata is a free-form jsonb column (see the migration and
      # Post.with_metadata) - its shape is deliberately not fixed, so
      # there's no finite list of keys to `permit` the way title/body/
      # lock_version have. `to_unsafe_h` is the accepted escape hatch for
      # exactly this case: a client-supplied nested object that's stored
      # as an opaque JSON document, never interpolated into SQL or used
      # to set arbitrary model attributes (mass assignment isn't a risk
      # here - it's a single JSON column, not a set of AR attributes).
      # Only merged in when the client actually sends it, so an update
      # that only touches title/body doesn't wipe out existing metadata.
      def permit_metadata(permitted)
        raw = params.dig(:post, :metadata)
        permitted[:metadata] = raw.to_unsafe_h if raw.is_a?(ActionController::Parameters)
        permitted
      end
    end
  end
end
