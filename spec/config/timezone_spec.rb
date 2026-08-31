require "rails_helper"

RSpec.describe "Timezone handling" do
  it "runs the app clock in UTC" do
    expect(Time.zone.name).to eq("UTC")
    expect(ActiveRecord.default_timezone).to eq(:utc)
  end

  it "normalizes a non-UTC offset string to UTC when parsed" do
    parsed = Time.zone.parse("2026-08-30T20:00:00-05:00")

    expect(parsed.utc).to eq(Time.utc(2026, 8, 31, 1, 0, 0))
  end

  it "persists a datetime attribute given in another offset as UTC, and reads it back as UTC" do
    user = create(:user)

    session = Session.create!(
      user: user,
      token_digest: SecureRandom.hex(32),
      expires_at: "2026-08-30T20:00:00-05:00"
    )

    expect(session.reload.expires_at.utc_offset).to eq(0)
    expect(session.expires_at).to eq(Time.utc(2026, 8, 31, 1, 0, 0))
  end
end
