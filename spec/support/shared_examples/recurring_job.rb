# Shared behavior every RecurringJob include gets for free - see that
# module for the heartbeat/self-perpetuation contract this verifies.
# Usage: `it_behaves_like "a recurring job"` inside the describe block for
# a job that includes RecurringJob.
RSpec.shared_examples "a recurring job" do
  describe "#perform" do
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

      ttl = Sidekiq.redis { |conn| conn.ttl(described_class.heartbeat_key) }
      expect(ttl).to be_within(2).of(described_class.heartbeat_ttl)
    end
  end

  describe ".claim_heartbeat!" do
    it "succeeds the first time and fails while the claim is still active" do
      expect(described_class.claim_heartbeat!).to be_truthy
      expect(described_class.claim_heartbeat!).to be_falsy
    end
  end
end
