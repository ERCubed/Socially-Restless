require "rails_helper"

RSpec.describe Rating, type: :model do
  # Persisted, not left to the factory's default association: a belongs_to
  # only syncs its foreign key column at save time if the associated
  # record was unsaved, so building `rating` against an already-persisted
  # user/post means user_id/post_id are set immediately, which the
  # uniqueness check below depends on.
  let(:user) { create(:user) }
  let(:post_record) { create(:post) }
  subject(:rating) { build(:rating, user: user, post: post_record) }

  describe "associations" do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:post) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:score) }

    it "is valid with valid attributes" do
      expect(rating).to be_valid
    end

    (1..5).each do |valid_score|
      it "accepts a score of #{valid_score}" do
        rating.score = valid_score
        expect(rating).to be_valid
      end
    end

    [ 0, 6, -1, 100 ].each do |invalid_score|
      it "rejects a score of #{invalid_score}" do
        rating.score = invalid_score
        expect(rating).not_to be_valid
      end
    end

    it "prevents a user from rating the same post twice" do
      create(:rating, user: user, post: post_record)

      expect(rating).not_to be_valid
      expect(rating.errors[:user_id]).to include("has already rated this post")
    end

    it "allows the same user to rate different posts" do
      create(:rating, user: user)

      expect(rating).to be_valid
    end

    it "allows different users to rate the same post" do
      create(:rating, post: post_record)

      expect(rating).to be_valid
    end
  end

  describe "cached post rating stats" do
    it "updates the post's cached stats on create" do
      rating.update!(score: 4)

      expect(post_record.reload.ratings_count).to eq(1)
      expect(post_record.reload.average_rating).to eq(4)
    end

    it "recomputes the post's cached stats when a rating is changed" do
      rating.update!(score: 4)
      other_rating = create(:rating, post: post_record, score: 2)

      expect(post_record.reload.average_rating).to eq(3) # (4 + 2) / 2

      other_rating.update!(score: 4)

      expect(post_record.reload.ratings_count).to eq(2)
      expect(post_record.reload.average_rating).to eq(4) # (4 + 4) / 2, not 5
    end
  end

  describe "notifications" do
    it "enqueues RatingNotificationJob after a successful create" do
      expect { rating.update!(score: 4) }.to have_enqueued_job(RatingNotificationJob).with(rating.id)
    end

    it "enqueues again when the rating is changed" do
      rating.update!(score: 4)

      expect { rating.update!(score: 5) }.to have_enqueued_job(RatingNotificationJob).with(rating.id)
    end

    it "does not enqueue anything when the update is invalid and never actually saves" do
      expect {
        expect(rating.update(score: 99)).to be false
      }.not_to have_enqueued_job(RatingNotificationJob)
    end
  end

  describe ".rate!" do
    it "creates a new rating when the user hasn't rated this post before" do
      result = nil

      expect {
        result = Rating.rate!(user: user, post: post_record, score: 4)
      }.to change(Rating, :count).by(1)

      expect(result.score).to eq(4)
      expect(result).to be_previously_new_record
    end

    it "updates the existing rating in place on a second call, without creating a duplicate" do
      Rating.rate!(user: user, post: post_record, score: 2)

      result = nil
      expect {
        result = Rating.rate!(user: user, post: post_record, score: 5)
      }.not_to change(Rating, :count)

      expect(result.score).to eq(5)
      expect(result).not_to be_previously_new_record
    end

    it "updates the post's cached stats as part of the same call" do
      Rating.rate!(user: user, post: post_record, score: 4)

      expect(post_record.reload.ratings_count).to eq(1)
      expect(post_record.reload.average_rating).to eq(4)
    end

    it "raises and creates nothing for an invalid score" do
      expect {
        expect { Rating.rate!(user: user, post: post_record, score: 9) }.to raise_error(ActiveRecord::RecordInvalid)
      }.not_to change(Rating, :count)
    end

    it "rolls back the rating write if the post's stats update fails, keeping both atomic" do
      allow_any_instance_of(Post).to receive(:recalculate_rating_stats!).and_raise("boom")

      expect {
        expect { Rating.rate!(user: user, post: post_record, score: 4) }.to raise_error("boom")
      }.not_to change(Rating, :count)
    end

    it "locks the post row before touching ratings, to serialize concurrent raters of the same post" do
      queries = []
      subscriber = ->(*, payload) { queries << payload[:sql] }

      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        Rating.rate!(user: user, post: post_record, score: 3)
      end

      expect(queries).to include(a_string_matching(/FOR UPDATE/i))
    end
  end

  describe "database constraints" do
    it "rejects a score outside 1..5 at the database level, even bypassing model validations" do
      rating.save!

      expect {
        rating.update_column(:score, 6)
      }.to raise_error(ActiveRecord::StatementInvalid, /ratings_score_range_check/)
    end

    it "rejects a duplicate (user, post) pair at the database level, even bypassing model validations" do
      rating.save!
      duplicate = build(:rating, user: user, post: post_record)

      expect {
        duplicate.save!(validate: false)
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
