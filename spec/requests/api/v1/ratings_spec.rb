require "rails_helper"

RSpec.describe "Api::V1::Ratings", type: :request do
  let(:user) { create(:user) }
  let(:session) { Session.start!(user: user) }
  let(:auth_headers) { { "Authorization" => "Bearer #{session.token}" } }
  let(:post_record) { create(:post) }

  describe "POST /api/v1/posts/:post_id/rating" do
    it "requires authentication" do
      post "/api/v1/posts/#{post_record.id}/rating", params: { rating: { score: 5 } }

      expect(response).to have_http_status(:unauthorized)
    end

    it "creates a new rating and returns 201" do
      expect {
        post "/api/v1/posts/#{post_record.id}/rating", params: { rating: { score: 4 } }, headers: auth_headers
      }.to change(Rating, :count).by(1)

      expect(response).to have_http_status(:created)
      body = response.parsed_body
      expect(body["rating"]["score"]).to eq(4)
      expect(body["rating"]["user_id"]).to eq(user.id)
      expect(body["rating"]["post_id"]).to eq(post_record.id)
    end

    it "updates the existing rating in place on a second call, without creating a duplicate" do
      post "/api/v1/posts/#{post_record.id}/rating", params: { rating: { score: 2 } }, headers: auth_headers

      expect {
        post "/api/v1/posts/#{post_record.id}/rating", params: { rating: { score: 5 } }, headers: auth_headers
      }.not_to change(Rating, :count)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["rating"]["score"]).to eq(5)
      expect(Rating.find_by(user: user, post: post_record).score).to eq(5)
    end

    it "lets different users rate the same post independently" do
      other_user = create(:user)
      other_session = Session.start!(user: other_user)

      post "/api/v1/posts/#{post_record.id}/rating", params: { rating: { score: 1 } }, headers: auth_headers
      post "/api/v1/posts/#{post_record.id}/rating", params: { rating: { score: 5 } },
                                                       headers: { "Authorization" => "Bearer #{other_session.token}" }

      expect(Rating.where(post: post_record).count).to eq(2)
      expect(Rating.find_by(user: user, post: post_record).score).to eq(1)
      expect(Rating.find_by(user: other_user, post: post_record).score).to eq(5)
    end

    it "rejects a score outside 1..5" do
      post "/api/v1/posts/#{post_record.id}/rating", params: { rating: { score: 6 } }, headers: auth_headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["details"]).to include(a_string_matching(/score/i))
    end

    it "rejects a missing score" do
      post "/api/v1/posts/#{post_record.id}/rating", params: { rating: { score: nil } }, headers: auth_headers

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "404s for a nonexistent post" do
      post "/api/v1/posts/0/rating", params: { rating: { score: 3 } }, headers: auth_headers

      expect(response).to have_http_status(:not_found)
    end

    it "404s for a soft-deleted post" do
      post_record.soft_delete!

      post "/api/v1/posts/#{post_record.id}/rating", params: { rating: { score: 3 } }, headers: auth_headers

      expect(response).to have_http_status(:not_found)
    end
  end
end
