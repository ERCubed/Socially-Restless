class ApplicationController < ActionController::API
  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
  rescue_from ActiveRecord::RecordInvalid, with: :render_unprocessable_entity
  rescue_from ActionController::ParameterMissing, with: :render_bad_request
  rescue_from Cursor::DecodeError, with: :render_bad_request
  rescue_from ActiveRecord::StaleObjectError, with: :render_conflict
  rescue_from ActiveRecord::ConnectionTimeoutError, with: :render_pool_exhausted

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

  # Raised by ActiveRecord::Locking::Optimistic when a record's lock_version
  # column doesn't match what's in the DB anymore - someone else updated it
  # since the client last read it. Generic, not tied to Post specifically:
  # any model that gains a lock_version column in the future is covered by
  # this automatically.
  def render_conflict(_exception)
    render_error(
      message: "This record was updated by someone else since you last loaded it. Reload and try again.",
      status: :conflict
    )
  end

  # Raised when every connection in the pool (config/database.yml) is
  # checked out and none frees up within checkout_timeout - the app is
  # genuinely overloaded relative to its current pool/thread sizing, not a
  # bug in a specific request. Worth a distinct response so a client (or a
  # load balancer) can tell "temporarily out of capacity, retry" apart
  # from a real server error, instead of surfacing a generic 500.
  def render_pool_exhausted(_exception)
    render_error(
      message: "The server is temporarily overloaded. Please try again shortly.",
      status: :service_unavailable
    )
  end
end
