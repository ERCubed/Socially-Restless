class RatingSerializer
  def initialize(rating)
    @rating = rating
  end

  def as_json(*)
    {
      id: rating.id,
      post_id: rating.post_id,
      user_id: rating.user_id,
      score: rating.score,
      created_at: rating.created_at,
      updated_at: rating.updated_at
    }
  end

  private

  attr_reader :rating
end
