require "rails_helper"

RSpec.describe "Connection pool exhaustion", type: :request do
  it "returns a 503 with the standard error envelope instead of a raw 500" do
    # Timeline, not /health: HealthController deliberately rescues every
    # subsystem check locally so it can report status instead of crashing,
    # which means it never reaches ApplicationController's rescue_from -
    # exactly the wrong endpoint to prove the *global* handler works.
    allow(Post).to receive(:kept).and_raise(
      ActiveRecord::ConnectionTimeoutError, "could not obtain a connection from the pool"
    )

    get "/api/v1/timeline"

    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body["error"]["message"]).to match(/temporarily overloaded/i)
  end
end
