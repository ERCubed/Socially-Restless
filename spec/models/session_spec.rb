require "rails_helper"

RSpec.describe Session, type: :model do
  subject { build(:session) }

  describe ".start!" do
    it "creates a session and exposes the raw token only in memory" do
      user = create(:user)

      session = Session.start!(user: user)

      expect(session.token).to be_present
      expect(session.token_digest).to eq(Digest::SHA256.hexdigest(session.token))
      expect(session.token_digest).not_to eq(session.token)
      expect(session.expires_at).to be_within(1.second).of(Session::EXPIRATION_TIME.from_now)
    end

    it "does not expose the raw token on a session reloaded from the database" do
      user = create(:user)
      session = Session.start!(user: user)

      reloaded = Session.find(session.id)

      expect(reloaded.token).to be_nil
    end
  end

  describe ".authenticate" do
    it "finds the session for a valid, unexpired raw token" do
      user = create(:user)
      session = Session.start!(user: user)

      expect(Session.authenticate(session.token)).to eq(session)
    end

    it "returns nil for an unknown token" do
      expect(Session.authenticate("bogus")).to be_nil
    end

    it "returns nil for a blank token" do
      expect(Session.authenticate(nil)).to be_nil
      expect(Session.authenticate("")).to be_nil
    end

    it "returns nil for an expired session" do
      user = create(:user)
      session = Session.start!(user: user)
      session.update!(expires_at: 1.minute.ago)

      expect(Session.authenticate(session.token)).to be_nil
    end
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:token_digest) }
    it { is_expected.to validate_uniqueness_of(:token_digest) }
  end
end
