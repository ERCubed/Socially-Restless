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
