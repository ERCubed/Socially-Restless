module Api
  module V1
    class BaseController < ApplicationController
      private

      def authenticate_user!
        render_error(message: "Unauthorized", status: :unauthorized) unless current_user
      end

      def current_session
        @current_session ||= Session.authenticate(bearer_token)
      end

      def current_user
        @current_user ||= current_session&.user
      end

      def bearer_token
        header = request.headers["Authorization"]
        header.split(" ").last if header&.start_with?("Bearer ")
      end

      def render_session(session, status:)
        render json: { user: UserSerializer.new(session.user).as_json, token: session.token }, status: status
      end
    end
  end
end
