# Stands in for real notification delivery (push/email/in-app). This app
# has no Notification model and no ActionMailer (removed entirely - see
# config/application.rb), so "delivery" here is a structured log line a
# real implementation would replace with an actual send. What's actually
# worth demonstrating is the pipeline - rated -> enqueued -> processed by
# a separate worker process - not the message itself.
class RatingNotificationJob < ApplicationJob
  queue_as :default

  def perform(rating_id)
    rating = Rating.find_by(id: rating_id)
    return unless rating

    Rails.logger.info(
      "[notification] #{rating.user.username} rated \"#{rating.post.title}\" " \
      "#{rating.score}/5 (post author: #{rating.post.user.username})"
    )
  end
end
