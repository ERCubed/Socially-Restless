require "rails_helper"

RSpec.describe "Rate limiting", type: :request do
  # Disabled by default in test (config/environments/test.rb) so the rest
  # of the suite can't trip its own throttles. Reset the counters after
  # too, not just before: leaving them dirty would make a later, unrelated
  # spec run in this same process fail if it happened to hit one of these
  # throttled paths enough times to matter.
  around do |example|
    Rack::Attack.enabled = true
    example.run
    # Rack::Attack.reset!, not a raw store.clear: it's scoped to keys under
    # rack-attack's own "rack::attack:" prefix, so it can't accidentally
    # wipe unrelated cache entries sharing the same Redis DB.
    Rack::Attack.reset!
    Rack::Attack.enabled = false
  end

  describe "login throttle" do
    let(:user) { create(:user) }
    let(:params) { { session: { email: user.email, password: "password123" } } }

    it "allows requests under the limit" do
      5.times do
        post "/api/v1/session", params: params
        expect(response).not_to have_http_status(:too_many_requests)
      end
    end

    it "throttles further requests once the limit is exceeded" do
      5.times { post "/api/v1/session", params: params }

      post "/api/v1/session", params: params

      expect(response).to have_http_status(:too_many_requests)
    end

    it "returns the standard error envelope and a Retry-After header when throttled" do
      5.times { post "/api/v1/session", params: params }
      post "/api/v1/session", params: params

      expect(response.headers["Retry-After"]).to be_present
      body = response.parsed_body
      expect(body["error"]["message"]).to be_present
    end

    it "tracks the throttle per IP, not globally" do
      5.times { post "/api/v1/session", params: params }

      post "/api/v1/session", params: params, headers: { "REMOTE_ADDR" => "10.0.0.99" }

      expect(response).not_to have_http_status(:too_many_requests)
    end
  end

  describe "signup throttle" do
    def signup_params(n)
      { user: { username: "throttleuser#{n}", email: "throttle#{n}@example.com", password: "password123" } }
    end

    it "throttles after 5 signups from the same IP within a minute" do
      5.times { |n| post "/api/v1/users", params: signup_params(n) }

      post "/api/v1/users", params: signup_params(99)

      expect(response).to have_http_status(:too_many_requests)
    end
  end

  describe "general API throttle" do
    it "does not throttle ordinary read traffic well under the limit" do
      10.times { get "/api/v1/timeline" }

      expect(response).not_to have_http_status(:too_many_requests)
    end

    it "does not apply to non-API paths" do
      # /up is outside the "/api/" prefix the general throttle matches on.
      300.times { get "/up" }

      expect(response).not_to have_http_status(:too_many_requests)
    end
  end
end
