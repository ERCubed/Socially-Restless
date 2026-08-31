require "rails_helper"

RSpec.describe User, type: :model do
  subject(:user) { build(:user) }

  describe "validations" do
    it { is_expected.to validate_presence_of(:username) }
    it { is_expected.to validate_presence_of(:email) }
    it { is_expected.to validate_length_of(:username).is_at_least(3).is_at_most(30) }
    it { is_expected.to validate_length_of(:password).is_at_least(8) }

    it "is valid with valid attributes" do
      expect(user).to be_valid
    end

    it "requires a unique username, case-insensitively" do
      create(:user, username: "Taken")
      user.username = "taken"
      expect(user).not_to be_valid
      expect(user.errors[:username]).to be_present
    end

    it "requires a unique email, case-insensitively" do
      create(:user, email: "taken@example.com")
      user.email = "TAKEN@example.com"
      expect(user).not_to be_valid
      expect(user.errors[:email]).to be_present
    end

    it "rejects malformed email addresses" do
      user.email = "not-an-email"
      expect(user).not_to be_valid
      expect(user.errors[:email]).to include("must be a valid email address")
    end

    it "rejects usernames with invalid characters" do
      user.username = "not valid!"
      expect(user).not_to be_valid
    end

    it "does not require a first or last name" do
      user.first_name = nil
      user.last_name = nil
      expect(user).to be_valid
    end

    it "rejects a first or last name over 50 characters" do
      user.first_name = "a" * 51
      user.last_name = "a" * 51
      expect(user).not_to be_valid
      expect(user.errors[:first_name]).to be_present
      expect(user.errors[:last_name]).to be_present
    end
  end

  describe "normalization" do
    it "downcases and strips the email before validation" do
      user.email = "  MixedCase@Example.com  "
      user.valid?
      expect(user.email).to eq("mixedcase@example.com")
    end

    it "strips whitespace from the username" do
      user.username = "  padded  "
      user.valid?
      expect(user.username).to eq("padded")
    end

    it "strips whitespace from first and last name" do
      user.first_name = "  Jane  "
      user.last_name = "  Doe  "
      user.valid?
      expect(user.first_name).to eq("Jane")
      expect(user.last_name).to eq("Doe")
    end
  end

  describe "password hashing" do
    it "hashes the password into password_digest and never stores it in plain text" do
      raw_password = user.password
      user.save!
      expect(user.password_digest).to be_present
      expect(user.password_digest).not_to eq(raw_password)
    end

    it "authenticates with the correct password" do
      raw_password = user.password
      user.save!
      expect(user.authenticate(raw_password)).to eq(user)
    end

    it "does not authenticate with an incorrect password" do
      user.save!
      expect(user.authenticate("wrongpassword")).to be false
    end
  end
end
