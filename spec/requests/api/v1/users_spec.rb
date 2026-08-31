require "rails_helper"

RSpec.describe "Api::V1::Users", type: :request do
  describe "POST /api/v1/users" do
    let(:valid_params) do
      {
        user: {
          username: "newuser", email: "newuser@example.com",
          password: "password123", password_confirmation: "password123",
          first_name: "Jane", last_name: "Doe"
        }
      }
    end

    it "creates a user and returns a token" do
      expect {
        post "/api/v1/users", params: valid_params
      }.to change(User, :count).by(1)

      expect(response).to have_http_status(:created)
      body = response.parsed_body
      expect(body["user"]["username"]).to eq("newuser")
      expect(body["user"]["first_name"]).to eq("Jane")
      expect(body["user"]["last_name"]).to eq("Doe")
      expect(body["user"]).not_to have_key("password_digest")
      expect(body["token"]).to be_present
    end

    it "creates a user without a first or last name" do
      params = valid_params
      params[:user].delete(:first_name)
      params[:user].delete(:last_name)

      post "/api/v1/users", params: params

      expect(response).to have_http_status(:created)
      body = response.parsed_body
      expect(body["user"]["first_name"]).to be_nil
      expect(body["user"]["last_name"]).to be_nil
    end

    it "returns a consistent error envelope for validation failures" do
      post "/api/v1/users", params: { user: { username: "x", email: "not-an-email", password: "short" } }

      expect(response).to have_http_status(:unprocessable_content)
      body = response.parsed_body
      expect(body["error"]["message"]).to eq("Validation failed")
      expect(body["error"]["details"]).to be_an(Array)
      expect(body["error"]["details"]).not_to be_empty
    end

    it "rejects duplicate usernames case-insensitively" do
      create(:user, username: "taken")
      post "/api/v1/users", params: { user: { username: "TAKEN", email: "unique@example.com", password: "password123" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["details"]).to include(a_string_matching(/username/i))
    end

    it "rejects duplicate emails case-insensitively" do
      create(:user, email: "taken@example.com")
      post "/api/v1/users", params: { user: { username: "uniqueuser", email: "TAKEN@example.com", password: "password123" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["details"]).to include(a_string_matching(/email/i))
    end
  end
end
