FactoryBot.define do
  factory :rating do
    association :user
    association :post
    score { rand(1..5) }
  end
end
