require "rails_helper"

RSpec.describe WarmTimelineCacheJob do
  it_behaves_like "a recurring job"

  describe "#perform" do
    it "writes the default Timeline first page to Rails.cache" do
      posts = create_list(:post, 3)
      cache_key = TimelineFeed.cache_key(per_page: TimelineFeed::DEFAULT_PER_PAGE, min_rating: nil)

      described_class.perform_now

      cached = Rails.cache.read(cache_key)
      expect(cached[:posts].map { |p| p[:id] }).to eq(posts.sort_by(&:created_at).reverse.map(&:id))
    end
  end
end
