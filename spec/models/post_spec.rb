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
    it "increments the in-memory view_count for each given post by 1" do
      posts = create_list(:post, 2, view_count: 3)

      Post.record_views!(posts)

      posts.each { |p| expect(p.view_count).to eq(4) }
    end

    it "does not write to Postgres directly - it defers to ViewCounts/FlushViewCountsJob" do
      post.save!

      update_queries = []
      subscriber = ->(*, payload) { update_queries << payload[:sql] if payload[:sql].match?(/\AUPDATE "posts"/i) }

      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        Post.record_views!([ post ])
      end

      expect(update_queries).to be_empty
      expect(post.reload.view_count).to eq(0) # unchanged until a flush happens
    end

    it "records the view in ViewCounts, which a flush later applies to Postgres" do
      post.save!

      Post.record_views!([ post ])
      FlushViewCountsJob.perform_now

      expect(post.reload.view_count).to eq(1)
    end

    it "does nothing for an empty list" do
      expect { Post.record_views!([]) }.not_to raise_error
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

  describe ".search" do
    it "matches a term appearing in the title" do
      matching = create(:post, title: "Ruby on Rails tips", body: "Nothing relevant here")
      create(:post, title: "Unrelated", body: "Also unrelated")

      expect(Post.search("rails")).to contain_exactly(matching)
    end

    it "matches a term appearing only in the body" do
      matching = create(:post, title: "Cooking", body: "A guide to baking sourdough bread")
      create(:post, title: "Cooking", body: "Nothing about that other topic")

      expect(Post.search("sourdough")).to contain_exactly(matching)
    end

    it "ranks a title match above a body-only match for the same term" do
      body_match = create(:post, title: "Unrelated title", body: "mentions astronomy briefly")
      title_match = create(:post, title: "All about astronomy", body: "unrelated body text")

      results = Post.search("astronomy").to_a

      expect(results).to eq([ title_match, body_match ])
    end

    it "returns no results for a term that doesn't appear anywhere" do
      create(:post, title: "Something", body: "Something else entirely")

      expect(Post.search("nonexistentterm")).to be_empty
    end

    it "does not raise for search input with stray punctuation" do
      create(:post, title: "Title", body: "Body")

      expect { Post.search("weird \"unterminated quote").to_a }.not_to raise_error
    end
  end

  describe ".with_metadata" do
    it "matches a post whose metadata is a superset of the given criteria" do
      matching = create(:post, metadata: { "tags" => [ "ruby", "rails" ] })
      create(:post, metadata: { "tags" => [ "python" ] })

      expect(Post.with_metadata("tags" => [ "ruby" ])).to contain_exactly(matching)
    end

    it "does not match a post with no metadata at all" do
      create(:post)

      expect(Post.with_metadata("tags" => [ "ruby" ])).to be_empty
    end

    it "defaults metadata to an empty hash, not null" do
      post = create(:post)

      expect(post.metadata).to eq({})
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
