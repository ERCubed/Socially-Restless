FactoryBot.define do
  factory :post do
    association :user
    title { Faker::Lorem.sentence(word_count: 4, random_words_to_add: 0) }
    body { Faker::Lorem.paragraph }
  end
end
