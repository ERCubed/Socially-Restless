class ApplicationController < ActionController::API
  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
  rescue_from ActiveRecord::RecordInvalid, with: :render_unprocessable_entity
  rescue_from ActionController::ParameterMissing, with: :render_bad_request
  rescue_from Cursor::DecodeError, with: :render_bad_request

  private

  # Consistent error envelope used across the whole API:
  #   { "error": { "message": "...", "details": ["...", ...] } }
  def render_error(message:, status:, details: [])
    render json: { error: { message: message, details: Array(details) } }, status: status
  end

  def render_not_found(exception)
    # Deliberately not exception.message: ActiveRecord's default message
    # embeds the failed SQL WHERE clause (column names, scoping, etc.),
    # which is internal detail we don't want to leak to API clients.
    model = exception.model || "Resource"
    render_error(message: "#{model} not found", status: :not_found)
  end

  def render_unprocessable_entity(exception)
    render_error(
      message: "Validation failed",
      status: :unprocessable_content,
      details: exception.record.errors.full_messages
    )
  end

  def render_bad_request(exception)
    render_error(message: exception.message, status: :bad_request)
  end
end
