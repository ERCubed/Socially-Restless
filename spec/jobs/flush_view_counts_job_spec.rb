require "rails_helper"

RSpec.describe FlushViewCountsJob do
  describe "#perform" do
    it "applies pending view counts to Postgres for multiple posts in one batch" do
      post_a = create(:post, view_count: 10)
      post_b = create(:post, view_count: 0)
      ViewCounts.record([ post_a.id, post_a.id, post_b.id ]) # 2 views on a, 1 on b

      update_queries = []
      subscriber = ->(*, payload) { update_queries << payload[:sql] if payload[:sql].match?(/\AUPDATE "?posts"?/i) }
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        described_class.perform_now
      end

      expect(update_queries.size).to eq(1) # one batched statement, not one per post
      expect(post_a.reload.view_count).to eq(12)
      expect(post_b.reload.view_count).to eq(1)
    end

    it "does nothing when there are no pending views" do
      expect_any_instance_of(ActiveRecord::ConnectionAdapters::AbstractAdapter)
        .not_to receive(:execute).with(a_string_matching(/UPDATE/i))

      expect { described_class.perform_now }.not_to raise_error
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
