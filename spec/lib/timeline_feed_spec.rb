require "rails_helper"

RSpec.describe TimelineFeed do
  describe ".scope" do
    it "excludes soft-deleted posts" do
      kept = create(:post)
      create(:post, deleted_at: Time.current)

      expect(described_class.scope).to contain_exactly(kept)
    end

    it "filters by min_rating when given" do
      low = create(:post, average_rating: 2.0)
      high = create(:post, average_rating: 4.5)

      expect(described_class.scope(min_rating: 4.0)).to contain_exactly(high)
      expect(described_class.scope).to contain_exactly(low, high)
    end
  end

  describe ".first_page" do
    it "returns the newest posts first, serialized with author info" do
      author = create(:user, username: "dana")
      older = create(:post, user: author, created_at: 1.hour.ago)
      newer = create(:post, user: author, created_at: 1.minute.ago)

      result = described_class.first_page(per_page: 10)

      expect(result[:posts].map { |p| p[:id] }).to eq([ newer.id, older.id ])
      expect(result[:posts].first[:author][:username]).to eq("dana")
    end

    it "reports has_more and a usable next_cursor when there are more rows than per_page" do
      posts = create_list(:post, 3)
      posts.each_with_index { |p, i| p.update_column(:created_at, i.hours.ago) }

      result = described_class.first_page(per_page: 2)

      expect(result[:posts].size).to eq(2)
      expect(result[:meta][:has_more]).to eq(true)
      expect(result[:meta][:next_cursor]).to be_present
    end

    it "reports has_more: false and a nil next_cursor when everything fits on one page" do
      create_list(:post, 2)

      result = described_class.first_page(per_page: 10)

      expect(result[:meta][:has_more]).to eq(false)
      expect(result[:meta][:next_cursor]).to be_nil
    end
  end

  describe ".cache_key" do
    it "varies by per_page and min_rating so distinct combinations don't collide" do
      key_a = described_class.cache_key(per_page: 10, min_rating: nil)
      key_b = described_class.cache_key(per_page: 20, min_rating: nil)
      key_c = described_class.cache_key(per_page: 10, min_rating: 4.0)

      expect([ key_a, key_b, key_c ].uniq.size).to eq(3)
    end
  end
end
