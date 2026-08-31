require "rails_helper"

RSpec.describe WarmTimelineCacheJob do
  describe "#perform" do
    it "writes the default Timeline first page to Rails.cache" do
      posts = create_list(:post, 3)
      cache_key = TimelineFeed.cache_key(per_page: TimelineFeed::DEFAULT_PER_PAGE, min_rating: nil)

      described_class.perform_now

      cached = Rails.cache.read(cache_key)
      expect(cached[:posts].map { |p| p[:id] }).to eq(posts.sort_by(&:created_at).reverse.map(&:id))
    end

    it "reschedules itself for the next interval outside of test env" do
      allow(Rails.env).to receive(:test?).and_return(false)

      expect { described_class.perform_now }.to have_enqueued_job(described_class)
    end

    it "does not reschedule itself in test env, to avoid runaway recurring jobs in specs" do
      expect { described_class.perform_now }.not_to have_enqueued_job(described_class)
    end

    it "refreshes the heartbeat TTL so a live chain isn't mistaken for a dead one" do
      described_class.claim_heartbeat!

      described_class.perform_now

      ttl = Sidekiq.redis { |conn| conn.ttl(described_class::HEARTBEAT_KEY) }
      expect(ttl).to be_within(2).of(described_class::HEARTBEAT_TTL)
    end
  end

  describe ".claim_heartbeat!" do
    it "succeeds the first time and fails while the claim is still active" do
      expect(described_class.claim_heartbeat!).to be_truthy
      expect(described_class.claim_heartbeat!).to be_falsy
    end
  end
end
