require "rails_helper"

RSpec.describe "Docs", type: :request do
  describe "GET /api-docs" do
    it "renders the HTML viewer" do
      get "/api-docs"

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("text/html")
      expect(response.body).to include("redoc")
    end
  end

  describe "GET /api-docs/openapi.yaml" do
    it "serves the generated OpenAPI file" do
      get "/api-docs/openapi.yaml"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("openapi:")
    end
  end
end
