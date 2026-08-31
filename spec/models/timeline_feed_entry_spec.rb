require "rails_helper"

RSpec.describe TimelineFeedEntry do
  describe ".refresh!" do
    it "picks up posts created since the last refresh" do
      post = create(:post, title: "Fresh from the view")

      expect(TimelineFeedEntry.find_by(id: post.id)).to be_nil

      described_class.refresh!

      expect(described_class.find_by(id: post.id).title).to eq("Fresh from the view")
    end

    it "excludes soft-deleted posts" do
      post = create(:post)
      described_class.refresh!
      expect(described_class.find_by(id: post.id)).to be_present

      post.soft_delete!
      described_class.refresh!

      expect(described_class.find_by(id: post.id)).to be_nil
    end

    it "does not raise when called twice in a row (CONCURRENTLY requires the view to already have data)" do
      create(:post)

      expect {
        described_class.refresh!
        described_class.refresh!
      }.not_to raise_error
    end

    it "self-heals a never-populated view by falling back to a plain (non-concurrent) refresh" do
      # Once a materialized view has been successfully refreshed even a
      # single time, Postgres marks it "populated" for good (a catalog
      # flag, not something a rolled-back transaction undoes) - so by the
      # time most examples run, the fallback branch below is never
      # actually exercised. Dropping and recreating WITH NO DATA (exactly
      # what db:test:prepare's structure.sql load produces on a fresh
      # database - see the comment above) is the only reliable way to put
      # the view back into the state this method exists to recover from.
      connection = ActiveRecord::Base.connection
      connection.execute("DROP MATERIALIZED VIEW timeline_feed")
      connection.execute("CREATE MATERIALIZED VIEW timeline_feed AS SELECT * FROM posts WHERE deleted_at IS NULL WITH NO DATA")
      connection.execute("CREATE UNIQUE INDEX index_timeline_feed_on_id ON timeline_feed (id)")

      post = create(:post)

      expect { described_class.refresh! }.not_to raise_error
      expect(described_class.find(post.id)).to be_present
    end
  end

  describe "read-only enforcement" do
    it "is marked read-only" do
      expect(described_class.new).to be_readonly
    end

    it "refuses to persist a write, even though the underlying view has the column" do
      post = create(:post, title: "Original")
      described_class.refresh!
      entry = described_class.find(post.id)

      expect { entry.update!(title: "hack-attempt") }.to raise_error(StandardError)

      raw_title = ActiveRecord::Base.connection.select_value(
        "SELECT title FROM timeline_feed WHERE id = #{post.id}"
      )
      expect(raw_title).to eq("Original")
    end
  end
end
