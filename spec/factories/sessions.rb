FactoryBot.define do
  factory :session do
    association :user
    token_digest { SecureRandom.hex(32) }
    expires_at { 24.hours.from_now }
  end
end
