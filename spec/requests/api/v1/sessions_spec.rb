require "rails_helper"

RSpec.describe "Api::V1::Sessions", type: :request do
  let(:user) { create(:user, password: "password123", password_confirmation: "password123") }

  describe "POST /api/v1/session" do
    it "logs in with valid credentials and returns a token" do
      post "/api/v1/session", params: { session: { email: user.email, password: "password123" } }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["user"]["id"]).to eq(user.id)
      expect(body["token"]).to be_present
    end

    it "logs in with mismatched email casing" do
      post "/api/v1/session", params: { session: { email: user.email.upcase, password: "password123" } }

      expect(response).to have_http_status(:ok)
    end

    it "rejects an incorrect password" do
      post "/api/v1/session", params: { session: { email: user.email, password: "wrongpassword" } }

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]["message"]).to eq("Invalid email or password")
    end

    it "rejects an unknown email" do
      post "/api/v1/session", params: { session: { email: "nobody@example.com", password: "password123" } }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "DELETE /api/v1/session" do
    it "returns no content when no token is presented" do
      delete "/api/v1/session"

      expect(response).to have_http_status(:no_content)
    end

    it "revokes the session so the token can no longer authenticate" do
      session = Session.start!(user: user)

      expect {
        delete "/api/v1/session", headers: { "Authorization" => "Bearer #{session.token}" }
      }.to change(Session, :count).by(-1)

      expect(response).to have_http_status(:no_content)
      expect(Session.authenticate(session.token)).to be_nil
    end
  end
end
