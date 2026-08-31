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

      # True only when a valid bearer token was presented AND it belongs to
      # the user identified by `author_id`. Deliberately not
      # `authenticate_user!` - endpoints that use this (viewing posts) are
      # public and must work with no token at all, so an anonymous viewer
      # or someone else's token both count as "not the author" rather than
      # being rejected.
      #
      # Takes an id, not a User record: callers already have the author's
      # id sitting on the row they loaded (e.g. `post.user_id`), and
      # comparing against that avoids an otherwise pointless extra query
      # to load the full author just to check identity (`post.user` would
      # do exactly that on every single post view).
      def self_view?(author_id)
        current_user.present? && current_user.id == author_id
      end

      def render_session(session, status:)
        render json: { user: UserSerializer.new(session.user).as_json, token: session.token }, status: status
      end
    end
  end
end
