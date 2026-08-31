module Api
  module V1
    class SessionsController < BaseController
      # POST /api/v1/session
      def create
        user = User.find_by(email: session_params[:email]&.strip&.downcase)

        if user&.authenticate(session_params[:password])
          session = Session.start!(user: user, user_agent: request.user_agent, ip_address: request.remote_ip)
          render_session(session, status: :ok)
        else
          render_error(message: "Invalid email or password", status: :unauthorized)
        end
      end

      # DELETE /api/v1/session
      # Sessions are DB-backed, so logout deletes the row outright: the token
      # stops authenticating immediately, from any device. If a token wasn't
      # presented or didn't match a live session, we still return 204 since
      # the end state the caller wants (not logged in) already holds.
      def destroy
        current_session&.destroy
        head :no_content
      end

      private

      def session_params
        params.require(:session).permit(:email, :password)
      end
    end
  end
end
