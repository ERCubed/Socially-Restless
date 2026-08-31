require "rails_helper"

RSpec.describe "Api::V1::Posts", type: :request do
  let(:user) { create(:user) }
  let(:session) { Session.start!(user: user) }
  let(:auth_headers) { { "Authorization" => "Bearer #{session.token}" } }

  describe "GET /api/v1/posts/:id" do
    it "does not require authentication" do
      post_record = create(:post)

      get "/api/v1/posts/#{post_record.id}"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["post"]["id"]).to eq(post_record.id)
    end

    it "404s for a soft-deleted post, without leaking query internals" do
      post_record = create(:post, deleted_at: Time.current)

      get "/api/v1/posts/#{post_record.id}"

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["error"]["message"]).to eq("Post not found")
    end

    it "404s for a nonexistent post" do
      get "/api/v1/posts/0"

      expect(response).to have_http_status(:not_found)
    end

    it "increments view_count for an anonymous viewer" do
      post_record = create(:post, view_count: 5)

      get "/api/v1/posts/#{post_record.id}"

      expect(response.parsed_body["post"]["view_count"]).to eq(6)
      expect(post_record.reload.view_count).to eq(6)
    end

    it "increments view_count for a viewer who is not the author" do
      post_record = create(:post, user: user, view_count: 0)
      viewer = create(:user)
      viewer_session = Session.start!(user: viewer)

      get "/api/v1/posts/#{post_record.id}", headers: { "Authorization" => "Bearer #{viewer_session.token}" }

      expect(response.parsed_body["post"]["view_count"]).to eq(1)
    end

    it "does not increment view_count when the author views their own post" do
      post_record = create(:post, user: user, view_count: 0)

      get "/api/v1/posts/#{post_record.id}", headers: auth_headers

      expect(response.parsed_body["post"]["view_count"]).to eq(0)
      expect(post_record.reload.view_count).to eq(0)
    end
  end

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

  describe "PATCH /api/v1/posts/:id" do
    let(:post_record) { create(:post, user: user, title: "Original title", body: "Original body") }

    it "requires authentication" do
      patch "/api/v1/posts/#{post_record.id}", params: { post: { title: "New", lock_version: 0 } }

      expect(response).to have_http_status(:unauthorized)
    end

    it "updates title/body and returns the new lock_version" do
      patch "/api/v1/posts/#{post_record.id}",
            params: { post: { title: "Updated title", body: "Updated body", lock_version: 0 } },
            headers: auth_headers

      expect(response).to have_http_status(:ok)
      body = response.parsed_body["post"]
      expect(body["title"]).to eq("Updated title")
      expect(body["body"]).to eq("Updated body")
      expect(body["lock_version"]).to eq(1)
    end

    it "requires lock_version to be present" do
      patch "/api/v1/posts/#{post_record.id}", params: { post: { title: "New" } }, headers: auth_headers

      expect(response).to have_http_status(:bad_request)
    end

    it "rejects a stale lock_version with 409, and does not apply the update" do
      # Two "clients" load the same post independently...
      client_a_version = post_record.lock_version
      client_b_version = post_record.lock_version

      # ...client A saves first, successfully advancing the version...
      patch "/api/v1/posts/#{post_record.id}",
            params: { post: { title: "Client A's edit", lock_version: client_a_version } },
            headers: auth_headers
      expect(response).to have_http_status(:ok)

      # ...client B, unaware, tries to save from the now-stale version it loaded.
      patch "/api/v1/posts/#{post_record.id}",
            params: { post: { title: "Client B's edit", lock_version: client_b_version } },
            headers: auth_headers

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["error"]["message"]).to match(/updated by someone else/i)
      expect(post_record.reload.title).to eq("Client A's edit")
    end

    it "ignores a client-supplied user_id" do
      other_user = create(:user)

      patch "/api/v1/posts/#{post_record.id}",
            params: { post: { title: "New", lock_version: 0, user_id: other_user.id } },
            headers: auth_headers

      expect(response.parsed_body["post"]["user_id"]).to eq(user.id)
    end

    it "returns a validation error for a title over 100 characters" do
      patch "/api/v1/posts/#{post_record.id}",
            params: { post: { title: "a" * 101, lock_version: 0 } },
            headers: auth_headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["details"]).to include(a_string_matching(/title/i))
    end

    it "404s for a post belonging to another user, without leaking query internals" do
      other_users_post = create(:post)

      patch "/api/v1/posts/#{other_users_post.id}",
            params: { post: { title: "New", lock_version: 0 } },
            headers: auth_headers

      expect(response).to have_http_status(:not_found)
      expect(other_users_post.reload.title).not_to eq("New")
    end

    it "404s for a soft-deleted post" do
      post_record.soft_delete!

      patch "/api/v1/posts/#{post_record.id}", params: { post: { title: "New", lock_version: 0 } }, headers: auth_headers

      expect(response).to have_http_status(:not_found)
    end

    it "404s for a nonexistent post" do
      patch "/api/v1/posts/0", params: { post: { title: "New", lock_version: 0 } }, headers: auth_headers

      expect(response).to have_http_status(:not_found)
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
