require "rails_helper"

RSpec.describe Post, type: :model do
  subject(:post) { build(:post) }

  describe "associations" do
    it { is_expected.to belong_to(:user) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:title) }
    it { is_expected.to validate_presence_of(:body) }
    it { is_expected.to validate_length_of(:title).is_at_most(100) }
    it { is_expected.to validate_length_of(:body).is_at_most(1000) }

    it "is valid with valid attributes" do
      expect(post).to be_valid
    end
  end

  describe "soft deletion" do
    it "is not deleted by default" do
      expect(post).not_to be_deleted
    end

    it "sets deleted_at and flips deleted? on soft_delete!" do
      post.save!

      expect { post.soft_delete! }.to change(post, :deleted_at).from(nil)
      expect(post).to be_deleted
    end

    it "clears deleted_at and flips deleted? back on restore!" do
      post.save!
      post.soft_delete!

      expect { post.restore! }.to change(post, :deleted_at).to(nil)
      expect(post).not_to be_deleted
    end

    it "does not remove the row from the database" do
      post.save!
      post.soft_delete!

      expect(Post.find(post.id)).to eq(post)
    end

    describe ".kept and .deleted scopes" do
      it "separates soft-deleted posts from active ones" do
        active_post = create(:post)
        deleted_post = create(:post, deleted_at: Time.current)

        expect(Post.kept).to contain_exactly(active_post)
        expect(Post.deleted).to contain_exactly(deleted_post)
      end
    end
  end

  describe "database constraints" do
    it "rejects a body over 1000 characters at the database level, even bypassing model validations" do
      post.save!
      # `update_column` skips validations/callbacks entirely, so this only
      # passes if `body`'s varchar(1000) column limit is actually enforced
      # by Postgres, not just by the Rails length validation above.
      expect {
        post.update_column(:body, "a" * 1001)
      }.to raise_error(ActiveRecord::StatementInvalid, /value too long/)
    end
  end
end
