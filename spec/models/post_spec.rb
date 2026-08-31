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

  describe ".record_views!" do
    it "increments view_count for each given post by 1" do
      posts = create_list(:post, 2, view_count: 3)

      Post.record_views!(posts)

      posts.each { |p| expect(p.reload.view_count).to eq(4) }
    end

    it "keeps the in-memory objects in sync with the DB write, without reloading" do
      post.save!
      post.view_count = 3
      post.save!

      Post.record_views!([ post ])

      expect(post.view_count).to eq(4)
      expect(post.reload.view_count).to eq(4)
    end

    it "does nothing for an empty list" do
      expect { Post.record_views!([]) }.not_to raise_error
    end

    it "increments via a single atomic UPDATE, not a read-modify-write" do
      post.save!

      update_queries = []
      subscriber = ->(*, payload) { update_queries << payload[:sql] if payload[:sql].match?(/\AUPDATE/i) }

      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        Post.record_views!([ post ])
      end

      expect(update_queries.size).to eq(1)
      expect(update_queries.first).to match(/view_count = view_count \+/i)
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

  describe "#recalculate_rating_stats!" do
    it "is zero with no ratings" do
      post.save!

      post.recalculate_rating_stats!

      expect(post.ratings_count).to eq(0)
      expect(post.average_rating).to eq(0)
    end

    it "computes the count and average from the post's ratings" do
      post.save!
      create(:rating, post: post, score: 2)
      create(:rating, post: post, score: 5)

      post.recalculate_rating_stats!

      expect(post.ratings_count).to eq(2)
      expect(post.average_rating).to eq(3.5)
    end

    it "rounds the average to 2 decimal places" do
      post.save!
      create(:rating, post: post, score: 1)
      create(:rating, post: post, score: 1)
      create(:rating, post: post, score: 5)

      post.recalculate_rating_stats!

      expect(post.average_rating).to eq(2.33)
    end

    it "persists the change and doesn't just mutate in memory" do
      post.save!
      create(:rating, post: post, score: 4)

      post.recalculate_rating_stats!

      expect(post.reload.ratings_count).to eq(1)
      expect(post.reload.average_rating).to eq(4)
    end
  end
end
