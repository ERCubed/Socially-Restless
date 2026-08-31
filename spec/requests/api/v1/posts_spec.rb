require "rails_helper"

RSpec.describe "Api::V1::Posts", type: :request do
  let(:user) { create(:user) }
  let(:session) { Session.start!(user: user) }
  let(:auth_headers) { { "Authorization" => "Bearer #{session.token}" } }

  describe "GET /api/v1/posts" do
    it "does not require authentication" do
      get "/api/v1/posts"

      expect(response).to have_http_status(:ok)
    end

    it "defaults to 10 posts per page" do
      create_list(:post, 15)

      get "/api/v1/posts"

      body = response.parsed_body
      expect(body["posts"].size).to eq(10)
      expect(body["meta"]["per_page"]).to eq(10)
      expect(body["meta"]["has_more"]).to eq(true)
      expect(body["meta"]["next_cursor"]).to be_present
    end

    it "accepts a per_page override" do
      create_list(:post, 15)

      get "/api/v1/posts", params: { per_page: 5 }

      body = response.parsed_body
      expect(body["posts"].size).to eq(5)
      expect(body["meta"]["per_page"]).to eq(5)
    end

    it "caps per_page at 100 to prevent an unbounded query" do
      get "/api/v1/posts", params: { per_page: 10_000 }

      expect(response.parsed_body["meta"]["per_page"]).to eq(100)
    end

    it "walks the full result set via next_cursor with no gaps or duplicates" do
      posts = create_list(:post, 25)
      posts.each_with_index { |p, i| p.update_column(:created_at, i.hours.ago) }
      newest_to_oldest_ids = posts.sort_by(&:created_at).reverse.map(&:id)

      seen_ids = []
      cursor = nil

      loop do
        get "/api/v1/posts", params: { per_page: 10, cursor: cursor }.compact
        body = response.parsed_body
        seen_ids.concat(body["posts"].map { |p| p["id"] })
        cursor = body["meta"]["next_cursor"]
        break unless body["meta"]["has_more"]
      end

      expect(seen_ids).to eq(newest_to_oldest_ids)
    end

    it "reports has_more: false and a nil next_cursor on the last page" do
      create_list(:post, 3)

      get "/api/v1/posts", params: { per_page: 10 }

      body = response.parsed_body
      expect(body["meta"]["has_more"]).to eq(false)
      expect(body["meta"]["next_cursor"]).to be_nil
    end

    it "still paginates correctly when posts share the same created_at, using id as a tiebreaker" do
      same_time = Time.current
      posts = create_list(:post, 12)
      posts.each { |p| p.update_column(:created_at, same_time) }
      newest_to_oldest_ids = posts.sort_by(&:id).reverse.map(&:id)

      get "/api/v1/posts", params: { per_page: 10 }
      first_page_ids = response.parsed_body["posts"].map { |p| p["id"] }
      cursor = response.parsed_body["meta"]["next_cursor"]

      get "/api/v1/posts", params: { per_page: 10, cursor: cursor }
      second_page_ids = response.parsed_body["posts"].map { |p| p["id"] }

      expect(first_page_ids + second_page_ids).to eq(newest_to_oldest_ids)
    end

    it "ignores a garbage per_page value rather than erroring" do
      get "/api/v1/posts", params: { per_page: "-5" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["meta"]["per_page"]).to eq(10)
    end

    it "returns a 400 for a malformed cursor instead of silently restarting" do
      get "/api/v1/posts", params: { cursor: "not-a-real-cursor" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]["message"]).to eq("invalid pagination cursor")
    end

    it "excludes soft-deleted posts" do
      kept = create(:post)
      deleted = create(:post, deleted_at: Time.current)

      get "/api/v1/posts"

      ids = response.parsed_body["posts"].map { |p| p["id"] }
      expect(ids).to include(kept.id)
      expect(ids).not_to include(deleted.id)
    end
  end

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
