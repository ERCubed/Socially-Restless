module Api
  module V1
    class RatingsController < BaseController
      before_action :authenticate_user!

      # POST /api/v1/posts/:post_id/rating
      # Upsert, not a plain create: a user has at most one rating per post,
      # so rating the same post twice updates that rating in place rather
      # than erroring or creating a second row. Rating.rate! wraps the
      # find-or-create, the post row lock, and the post's cached stats
      # update in one transaction - see there for why the lock matters.
      # A validation failure raises ActiveRecord::RecordInvalid, handled
      # by ApplicationController's shared rescue_from.
      def create
        post = Post.kept.find(params[:post_id])
        rating = Rating.rate!(user: current_user, post: post, score: rating_params[:score])

        render json: { rating: RatingSerializer.new(rating).as_json }, status: rating.previously_new_record? ? :created : :ok
      end

      private

      def rating_params
        params.require(:rating).permit(:score)
      end
    end
  end
end
