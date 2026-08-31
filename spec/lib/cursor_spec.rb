require "rails_helper"

RSpec.describe Cursor do
  describe ".encode / .decode" do
    it "round-trips a timestamp and id" do
      timestamp = Time.zone.parse("2026-08-31T12:00:00Z")

      encoded = described_class.encode(timestamp, 42)
      decoded = described_class.decode(encoded)

      expect(decoded.timestamp).to eq(timestamp)
      expect(decoded.id).to eq(42)
    end

    it "returns nil for a blank cursor" do
      expect(described_class.decode(nil)).to be_nil
      expect(described_class.decode("")).to be_nil
    end

    it "raises DecodeError for a malformed cursor" do
      expect { described_class.decode("not-a-real-cursor") }.to raise_error(described_class::DecodeError)
    end

    it "raises DecodeError for validly-encoded base64 that doesn't decode to a cursor shape" do
      garbage = Base64.urlsafe_encode64("nothing_useful_here")

      expect { described_class.decode(garbage) }.to raise_error(described_class::DecodeError)
    end
  end
end
