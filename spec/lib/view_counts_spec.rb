require "rails_helper"

RSpec.describe ViewCounts do
  describe ".record and .flush!" do
    it "accumulates multiple views for the same post into one pending count" do
      described_class.record(1)
      described_class.record(1)
      described_class.record(1)

      expect(described_class.flush!).to eq(1 => 3)
    end

    it "tracks multiple posts independently in a single batched call" do
      described_class.record([ 1, 2, 1 ])

      expect(described_class.flush!).to eq(1 => 2, 2 => 1)
    end

    it "clears counters atomically on flush, so a second flush finds nothing left" do
      described_class.record(1)

      expect(described_class.flush!).to eq(1 => 1)
      expect(described_class.flush!).to eq({})
    end

    it "returns an empty hash when nothing is pending" do
      expect(described_class.flush!).to eq({})
    end

    it "does nothing for an empty list" do
      expect { described_class.record([]) }.not_to raise_error
      expect(described_class.flush!).to eq({})
    end
  end

  describe ".record" do
    it "swallows a Redis error rather than raising - a lost view is an acceptable miss" do
      allow(described_class.redis).to receive(:pipelined).and_raise(Redis::CannotConnectError, "down")

      expect { described_class.record(1) }.not_to raise_error
    end
  end
end
