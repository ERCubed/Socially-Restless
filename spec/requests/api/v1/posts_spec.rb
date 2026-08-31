require "rails_helper"

RSpec.describe "Api::V1::Posts", type: :request do
  let(:user) { create(:user) }
  let(:session) { Session.start!(user: user) }
  let(:auth_headers) { { "Authorization" => "Bearer #{session.token}" } }

  describe "POST /api/v1/posts" do
    let(:valid_params) { { post: { title: "Hello world", body: "This is my first post." } } }

    it "requires authentication" do
      post "/api/v1/posts", params: valid_params

      expect(response).to have_http_status(:unauthorized)
    end

    it "creates a post owned by the current user" do
      expect {
        post "/api/v1/posts", params: valid_params, headers: auth_headers
      }.to change(Post, :count).by(1)

      expect(response).to have_http_status(:created)
      body = response.parsed_body
      expect(body["post"]["title"]).to eq("Hello world")
      expect(body["post"]["body"]).to eq("This is my first post.")
      expect(body["post"]["user_id"]).to eq(user.id)
    end

    it "ignores a client-supplied user_id and always attributes the post to the current user" do
      other_user = create(:user)

      post "/api/v1/posts", params: { post: { title: "Hello", body: "Body", user_id: other_user.id } }, headers: auth_headers

      expect(response.parsed_body["post"]["user_id"]).to eq(user.id)
    end

    it "returns a validation error for a blank title" do
      post "/api/v1/posts", params: { post: { title: "", body: "Body" } }, headers: auth_headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["details"]).to include(a_string_matching(/title/i))
    end

    it "returns a validation error for a title over 100 characters" do
      post "/api/v1/posts", params: { post: { title: "a" * 101, body: "Body" } }, headers: auth_headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["details"]).to include(a_string_matching(/title/i))
    end

    it "returns a validation error for a body over 1000 characters" do
      post "/api/v1/posts", params: { post: { title: "Title", body: "a" * 1001 } }, headers: auth_headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["details"]).to include(a_string_matching(/body/i))
    end
  end

  describe "DELETE /api/v1/posts/:id" do
    let(:post_record) { create(:post, user: user) }

    it "requires authentication" do
      delete "/api/v1/posts/#{post_record.id}"

      expect(response).to have_http_status(:unauthorized)
    end

    it "soft deletes the post without removing the row" do
      delete "/api/v1/posts/#{post_record.id}", headers: auth_headers

      expect(response).to have_http_status(:no_content)
      expect(post_record.reload).to be_deleted
    end

    it "404s for a post belonging to another user, without leaking query internals" do
      other_users_post = create(:post)

      delete "/api/v1/posts/#{other_users_post.id}", headers: auth_headers

      expect(response).to have_http_status(:not_found)
      expect(other_users_post.reload).not_to be_deleted
      expect(response.parsed_body["error"]["message"]).to eq("Post not found")
      expect(response.body).not_to include("WHERE")
    end

    it "404s for a post that is already soft deleted" do
      post_record.soft_delete!

      delete "/api/v1/posts/#{post_record.id}", headers: auth_headers

      expect(response).to have_http_status(:not_found)
    end

    it "404s for a nonexistent post" do
      delete "/api/v1/posts/0", headers: auth_headers

      expect(response).to have_http_status(:not_found)
    end
  end
end
