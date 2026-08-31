require "rails_helper"

RSpec.describe RatingNotificationJob, type: :job do
  it "logs a message naming the rater, the post, the score, and the post's author" do
    rater = create(:user, username: "rater_username")
    author = create(:user, username: "author_username")
    post_record = create(:post, user: author, title: "A great post")
    rating = create(:rating, user: rater, post: post_record, score: 4)

    # allow, not a strict expect(...).to receive: ActiveJob's own
    # instrumentation logs other :info messages around perform_now (e.g.
    # "Performing RatingNotificationJob..."), which a bare `receive(:info)`
    # expectation would intercept and fail on for not matching our string.
    allow(Rails.logger).to receive(:info).and_call_original

    described_class.perform_now(rating.id)

    expect(Rails.logger).to have_received(:info).with(
      a_string_matching(/rater_username.*A great post.*4\/5.*author_username/)
    )
  end

  it "does nothing (does not raise) if the rating no longer exists" do
    expect { described_class.perform_now(0) }.not_to raise_error
  end
end
