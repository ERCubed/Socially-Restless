require "rails_helper"

RSpec.describe "Api::V1::Timeline", type: :request do
  describe "GET /api/v1/timeline" do
    it "does not require authentication" do
      get "/api/v1/timeline"

      expect(response).to have_http_status(:ok)
    end

    it "returns posts from all users, newest first" do
      alice = create(:user, username: "alice")
      bob = create(:user, username: "bob")
      older = create(:post, user: alice, created_at: 1.hour.ago)
      newer = create(:post, user: bob, created_at: 1.minute.ago)

      get "/api/v1/timeline"

      ids = response.parsed_body["posts"].map { |p| p["id"] }
      expect(ids).to eq([ newer.id, older.id ])
    end

    it "includes author information" do
      user = create(:user, username: "carol", first_name: "Carol")
      post_record = create(:post, user: user)

      get "/api/v1/timeline"

      author = response.parsed_body["posts"].first["author"]
      expect(author["id"]).to eq(user.id)
      expect(author["username"]).to eq("carol")
      expect(author["first_name"]).to eq("Carol")
    end

    it "includes average_rating, ratings_count, and view_count" do
      post_record = create(:post, view_count: 3)
      create(:rating, post: post_record, score: 4)
      create(:rating, post: post_record, score: 2)

      get "/api/v1/timeline"

      entry = response.parsed_body["posts"].first
      expect(entry["average_rating"]).to eq(3.0)
      expect(entry["ratings_count"]).to eq(2)
      expect(entry["view_count"]).to eq(3)
    end

    it "excludes soft-deleted posts" do
      kept = create(:post)
      create(:post, deleted_at: Time.current)

      get "/api/v1/timeline"

      ids = response.parsed_body["posts"].map { |p| p["id"] }
      expect(ids).to eq([ kept.id ])
    end

    it "does not increment view_count for posts shown in the feed" do
      post_record = create(:post, view_count: 0)

      get "/api/v1/timeline"

      expect(post_record.reload.view_count).to eq(0)
    end

    it "defaults to 10 posts per page and reports has_more/next_cursor" do
      create_list(:post, 15)

      get "/api/v1/timeline"

      body = response.parsed_body
      expect(body["posts"].size).to eq(10)
      expect(body["meta"]["per_page"]).to eq(10)
      expect(body["meta"]["has_more"]).to eq(true)
      expect(body["meta"]["next_cursor"]).to be_present
    end

    it "walks the full result set via next_cursor with no gaps or duplicates" do
      posts = create_list(:post, 25)
      posts.each_with_index { |p, i| p.update_column(:created_at, i.hours.ago) }
      newest_to_oldest_ids = posts.sort_by(&:created_at).reverse.map(&:id)

      seen_ids = []
      cursor = nil

      loop do
        get "/api/v1/timeline", params: { per_page: 10, cursor: cursor }.compact
        body = response.parsed_body
        seen_ids.concat(body["posts"].map { |p| p["id"] })
        cursor = body["meta"]["next_cursor"]
        break unless body["meta"]["has_more"]
      end

      expect(seen_ids).to eq(newest_to_oldest_ids)
    end

    it "returns a 400 for a malformed cursor instead of silently restarting" do
      get "/api/v1/timeline", params: { cursor: "not-a-real-cursor" }

      expect(response).to have_http_status(:bad_request)
    end

    it "filters to posts at or above the given minimum average rating" do
      low = create(:post)
      create(:rating, post: low, score: 2)
      high = create(:post)
      create(:rating, post: high, score: 5)

      get "/api/v1/timeline", params: { min_rating: 4 }

      ids = response.parsed_body["posts"].map { |p| p["id"] }
      expect(ids).to eq([ high.id ])
    end

    it "treats the minimum as inclusive" do
      post_record = create(:post)
      create(:rating, post: post_record, score: 4)

      get "/api/v1/timeline", params: { min_rating: 4 }

      expect(response.parsed_body["posts"].map { |p| p["id"] }).to eq([ post_record.id ])
    end

    it "includes unrated posts (average_rating 0) when there's no filter, but excludes them from a positive min_rating" do
      unrated = create(:post)
      rated = create(:post)
      create(:rating, post: rated, score: 3)

      get "/api/v1/timeline", params: { min_rating: 1 }

      ids = response.parsed_body["posts"].map { |p| p["id"] }
      expect(ids).to eq([ rated.id ])
      expect(ids).not_to include(unrated.id)
    end

    it "ignores a blank or garbage min_rating rather than erroring" do
      post_record = create(:post)

      get "/api/v1/timeline", params: { min_rating: "not-a-number" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["posts"].map { |p| p["id"] }).to eq([ post_record.id ])
    end

    it "eager loads authors, so the query count doesn't grow with the number of distinct posters" do
      create_list(:post, 10) # 10 distinct authors, via the factory's default association

      queries = []
      subscriber = ->(*, payload) { queries << payload[:sql] if payload[:sql].match?(/\ASELECT/i) }

      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        get "/api/v1/timeline"
      end

      # One query for posts, one for the preloaded users - not one-per-post.
      expect(queries.size).to eq(2)
    end

    describe "caching" do
      def select_query_count
        queries = []
        subscriber = ->(*, payload) { queries << payload[:sql] if payload[:sql].match?(/\ASELECT/i) }
        ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
        queries.size
      end

      it "serves the second identical (no-cursor) request from cache, without re-querying" do
        create(:post)
        get "/api/v1/timeline"
        expect(select_query_count { get "/api/v1/timeline" }).to eq(0)
      end

      it "returns the cached response body, not just skipping the query" do
        post_record = create(:post)
        get "/api/v1/timeline"
        first_body = response.parsed_body

        create(:post) # would appear in a fresh, uncached query

        get "/api/v1/timeline"
        expect(response.parsed_body).to eq(first_body)
        expect(response.parsed_body["posts"].map { |p| p["id"] }).to eq([ post_record.id ])
      end

      it "never caches a request that includes a cursor" do
        create_list(:post, 3)
        first = get_json("/api/v1/timeline", per_page: 1)
        cursor = first["meta"]["next_cursor"]

        expect(select_query_count { get "/api/v1/timeline", params: { per_page: 1, cursor: cursor } }).to be > 0
        expect(select_query_count { get "/api/v1/timeline", params: { per_page: 1, cursor: cursor } }).to be > 0
      end

      it "keeps distinct cache entries per per_page" do
        create_list(:post, 3)
        get "/api/v1/timeline", params: { per_page: 1 }
        expect(response.parsed_body["posts"].size).to eq(1)

        expect(select_query_count { get "/api/v1/timeline", params: { per_page: 2 } }).to be > 0
        expect(response.parsed_body["posts"].size).to eq(2)
      end

      it "keeps distinct cache entries per min_rating" do
        low = create(:post)
        create(:rating, post: low, score: 2)
        high = create(:post)
        create(:rating, post: high, score: 5)

        get "/api/v1/timeline"
        expect(response.parsed_body["posts"].size).to eq(2)

        expect(select_query_count { get "/api/v1/timeline", params: { min_rating: 4 } }).to be > 0
        expect(response.parsed_body["posts"].map { |p| p["id"] }).to eq([ high.id ])
      end

      it "re-queries once the cache entry actually expires in Redis" do
        stub_const("Api::V1::TimelineController::CACHE_EXPIRY", 0.05.seconds)
        create(:post)
        get "/api/v1/timeline"

        sleep 0.1

        create(:post)
        expect(select_query_count { get "/api/v1/timeline" }).to be > 0
        expect(response.parsed_body["posts"].size).to eq(2)
      end

      def get_json(path, **params)
        get path, params: params
        response.parsed_body
      end
    end
  end
end
