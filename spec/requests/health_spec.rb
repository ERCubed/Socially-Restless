require "rails_helper"

RSpec.describe "Health", type: :request do
  describe "GET /health" do
    it "reports ok with all real subsystems healthy" do
      get "/health"

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["status"]).to eq("ok")
      expect(body["subsystems"]["database"]).to include("status" => "ok", "critical" => true)
      expect(body["subsystems"]["database"]["latency_ms"]).to be_a(Numeric)
      # Test's Rails.cache is a real redis_cache_store (see
      # config/environments/test.rb), unlike development's default
      # :null_store, so this is a genuine Redis round trip too.
      expect(body["subsystems"]["cache"]).to include("status" => "ok", "critical" => false)
      expect(body["subsystems"]["rate_limiter"]).to include("status" => "ok", "critical" => false)
    end

    it "returns 503 and status unavailable when the database is unreachable" do
      allow(ActiveRecord::Base.connection).to receive(:execute).and_raise(PG::ConnectionBad, "could not connect")

      get "/health"

      expect(response).to have_http_status(:service_unavailable)
      body = response.parsed_body
      expect(body["status"]).to eq("unavailable")
      expect(body["subsystems"]["database"]).to include("status" => "error", "critical" => true, "error" => "PG::ConnectionBad")
    end

    it "returns 200 and status degraded (not unavailable) when only the cache is unreachable" do
      allow(Rails.cache.redis).to receive(:with).and_raise(Redis::CannotConnectError, "connection refused")

      get "/health"

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["status"]).to eq("degraded")
      expect(body["subsystems"]["cache"]).to include("status" => "error", "critical" => false, "error" => "Redis::CannotConnectError")
      expect(body["subsystems"]["database"]["status"]).to eq("ok")
    end

    it "returns 200 and status degraded when only the rate limiter's Redis is unreachable" do
      allow(Rack::Attack.cache.store.redis).to receive(:with).and_raise(Redis::CannotConnectError, "connection refused")

      get "/health"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["status"]).to eq("degraded")
      expect(response.parsed_body["subsystems"]["rate_limiter"]).to include("status" => "error")
    end

    it "reports cache as not_configured, not a false ok, when Rails.cache isn't Redis-backed" do
      allow(Rails.cache).to receive(:respond_to?).with(:redis).and_return(false)

      get "/health"

      expect(response.parsed_body["subsystems"]["cache"]).to eq("status" => "not_configured", "critical" => false)
      expect(response.parsed_body["status"]).to eq("ok") # not_configured isn't a failure
    end

    it "does not require authentication" do
      get "/health"

      expect(response).not_to have_http_status(:unauthorized)
    end

    describe "latest_commit" do
      # HealthController.latest_commit memoizes at the class level (it
      # can't change for the life of a process), so tests that stub its
      # inputs need to reset that memoization or they'd leak into each
      # other - whichever example runs first would "win" for the rest.
      around do |example|
        HealthController.instance_variable_set(:@latest_commit, nil)
        example.run
        HealthController.instance_variable_set(:@latest_commit, nil)
      end

      it "reports the real current commit, truncated to 10 characters" do
        get "/health"

        expect(response.parsed_body["latest_commit"]).to eq(`git rev-parse HEAD`.strip.slice(0, 10))
      end

      it "prefers GIT_COMMIT when set, truncated the same way" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("GIT_COMMIT").and_return("deadbeef1234567890")

        get "/health"

        expect(response.parsed_body["latest_commit"]).to eq("deadbeef12")
      end

      it "is nil, not an error, when neither GIT_COMMIT nor .git is available" do
        allow(HealthController).to receive(:read_git_head).and_return(nil)

        get "/health"

        expect(response.parsed_body["latest_commit"]).to be_nil
        expect(response.parsed_body["status"]).to eq("ok") # doesn't affect health status
      end

      it "is not one of the pass/fail subsystem checks" do
        get "/health"

        expect(response.parsed_body["subsystems"].keys).not_to include("latest_commit")
      end
    end

    describe ".read_git_head" do
      it "resolves a detached HEAD (a raw SHA, not a symbolic ref) directly" do
        allow(File).to receive(:read).and_call_original
        allow(File).to receive(:read).with(Rails.root.join(".git", "HEAD")).and_return("abc123def456\n")

        expect(HealthController.read_git_head).to eq("abc123def456")
      end

      it "returns nil instead of raising if .git can't be read" do
        allow(File).to receive(:read).and_raise(Errno::ENOENT)

        expect(HealthController.read_git_head).to be_nil
      end
    end
  end
end
