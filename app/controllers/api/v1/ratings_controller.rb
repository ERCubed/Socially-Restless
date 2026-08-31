module Api
  module V1
    class RatingsController < BaseController
      before_action :authenticate_user!

      # POST /api/v1/posts/:post_id/rating
      # Upsert, not a plain create: a user has at most one rating per post,
      # so rating the same post twice updates that rating in place rather
      # than erroring or creating a second row. find_or_initialize_by uses
      # the (user_id, post_id) unique index as its lookup path; that same
      # index is what actually guarantees "only one rating per post" under
      # concurrent requests, since this find-then-save is not itself atomic
      # (see the model/migration for why that's acceptable for now).
      def create
        post = Post.kept.find(params[:post_id])
        rating = Rating.find_or_initialize_by(user: current_user, post: post)
        newly_rated = rating.new_record?
        rating.score = rating_params[:score]

        if rating.save
          render json: { rating: RatingSerializer.new(rating).as_json }, status: newly_rated ? :created : :ok
        else
          render_error(message: "Validation failed", status: :unprocessable_content, details: rating.errors.full_messages)
        end
      end

      private

      def rating_params
        params.require(:rating).permit(:score)
      end
    end
  end
end
