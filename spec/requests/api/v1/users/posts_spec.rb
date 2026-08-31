require "rails_helper"

RSpec.describe "Api::V1::Users::Posts", type: :request do
  let(:user) { create(:user, username: "alice") }

  describe "GET /api/v1/users/:username/posts" do
    it "does not require authentication" do
      get "/api/v1/users/#{user.username}/posts"

      expect(response).to have_http_status(:ok)
    end

    it "returns only that user's posts, newest first" do
      other_user = create(:user)
      older = create(:post, user: user, created_at: 1.hour.ago)
      newer = create(:post, user: user, created_at: 1.minute.ago)
      create(:post, user: other_user)

      get "/api/v1/users/#{user.username}/posts"

      ids = response.parsed_body["posts"].map { |p| p["id"] }
      expect(ids).to eq([ newer.id, older.id ])
    end

    it "excludes that user's soft-deleted posts" do
      kept = create(:post, user: user)
      create(:post, user: user, deleted_at: Time.current)

      get "/api/v1/users/#{user.username}/posts"

      ids = response.parsed_body["posts"].map { |p| p["id"] }
      expect(ids).to eq([ kept.id ])
    end

    it "returns a blank array, not a 404, for an unknown username" do
      get "/api/v1/users/nobody-with-this-name/posts"

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["posts"]).to eq([])
      expect(body["meta"]).to include("total_count" => 0)
    end

    it "defaults to 10 posts per page" do
      create_list(:post, 15, user: user)

      get "/api/v1/users/#{user.username}/posts"

      body = response.parsed_body
      expect(body["posts"].size).to eq(10)
      expect(body["meta"]).to eq(
        "page" => 1, "per_page" => 10, "total_count" => 15, "total_pages" => 2
      )
    end

    it "accepts page and per_page overrides" do
      create_list(:post, 15, user: user)

      get "/api/v1/users/#{user.username}/posts", params: { page: 2, per_page: 5 }

      body = response.parsed_body
      expect(body["posts"].size).to eq(5)
      expect(body["meta"]["page"]).to eq(2)
      expect(body["meta"]["per_page"]).to eq(5)
    end

    it "caps per_page at 100 to prevent an unbounded query" do
      get "/api/v1/users/#{user.username}/posts", params: { per_page: 10_000 }

      expect(response.parsed_body["meta"]["per_page"]).to eq(100)
    end

    it "ignores garbage page/per_page values rather than erroring" do
      get "/api/v1/users/#{user.username}/posts", params: { page: "not-a-number", per_page: "-5" }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["meta"]["page"]).to eq(1)
      expect(body["meta"]["per_page"]).to eq(10)
    end

    it "increments view_count for every post on the page for an anonymous viewer" do
      posts = create_list(:post, 3, user: user, view_count: 0)

      get "/api/v1/users/#{user.username}/posts"

      expect(response.parsed_body["posts"].map { |p| p["view_count"] }).to all(eq(1))
      posts.each { |p| expect(p.reload.view_count).to eq(1) }
    end

    it "increments view_count when the viewer is not the profile's own user" do
      posts = create_list(:post, 2, user: user, view_count: 0)
      viewer_session = Session.start!(user: create(:user))

      get "/api/v1/users/#{user.username}/posts", headers: { "Authorization" => "Bearer #{viewer_session.token}" }

      expect(response.parsed_body["posts"].map { |p| p["view_count"] }).to all(eq(1))
      posts.each { |p| expect(p.reload.view_count).to eq(1) }
    end

    it "does not increment view_count when the profile's own user is viewing" do
      posts = create_list(:post, 2, user: user, view_count: 0)
      own_session = Session.start!(user: user)

      get "/api/v1/users/#{user.username}/posts", headers: { "Authorization" => "Bearer #{own_session.token}" }

      expect(response.parsed_body["posts"].map { |p| p["view_count"] }).to all(eq(0))
      posts.each { |p| expect(p.reload.view_count).to eq(0) }
    end
  end
end
