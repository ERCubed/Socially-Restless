module Api
  module V1
    class UsersController < BaseController
      # POST /api/v1/users
      def create
        user = User.new(user_params)

        if user.save
          session = Session.start!(user: user, user_agent: request.user_agent, ip_address: request.remote_ip)
          render_session(session, status: :created)
        else
          render_error(message: "Validation failed", status: :unprocessable_content, details: user.errors.full_messages)
        end
      end

      private

      def user_params
        params.require(:user).permit(:username, :email, :password, :password_confirmation)
      end
    end
  end
end
