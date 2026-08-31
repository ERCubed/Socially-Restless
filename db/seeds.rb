# Development/demo data for exercising the API by hand. Idempotent - safe
# to run against a database that already has this seed data in it (each
# find_or_create_by! matches on a stable, deterministic key, and only sets
# the rest of the record's attributes the first time it's created).
#
#   bin/rails db:seed
#
# Every seeded user shares the same password so you can log in as any of
# them without looking anything up:
SEED_PASSWORD = "password123"

USERS = [
  { username: "alice", email: "alice@example.com", first_name: "Alice", last_name: "Anderson" },
  { username: "bob", email: "bob@example.com", first_name: "Bob", last_name: "Baker" },
  { username: "carol", email: "carol@example.com", first_name: "Carol", last_name: "Chen" },
  { username: "dave", email: "dave@example.com", first_name: "Dave", last_name: "Diaz" },
  { username: "erin", email: "erin@example.com", first_name: "Erin", last_name: "Evans" }
].freeze

users = USERS.map do |attrs|
  User.find_or_create_by!(username: attrs[:username]) do |user|
    user.email = attrs[:email]
    user.first_name = attrs[:first_name]
    user.last_name = attrs[:last_name]
    user.password = SEED_PASSWORD
    user.password_confirmation = SEED_PASSWORD
  end
end

posts = users.flat_map do |user|
  post_count = 3 + (user.id % 4) # a varied-but-stable 3..6 per user

  Array.new(post_count) do |i|
    title = "#{user.first_name}'s post ##{i + 1}"

    Post.find_or_create_by!(user: user, title: title) do |post|
      post.body = Faker::Lorem.paragraph(sentence_count: 3)
      post.created_at = (post_count - i).days.ago
      post.view_count = rand(50..500)
    end
  end
end

# One deliberately soft-deleted post, so `Post.kept` filtering is visible
# in seeded data rather than only in tests.
if (post_to_delete = posts.first) && !post_to_delete.deleted?
  post_to_delete.soft_delete!
end

# Deterministic (not sampled) so re-seeding doesn't keep adding new
# ratings from a different random draw each time: every user rates every
# *other* user's post, alternating so ~half the pairs actually get one -
# real variety in the resulting average_rating without rating everything.
posts.each_with_index do |post, i|
  next if post.deleted?

  (users - [ post.user ]).each_with_index do |rater, j|
    next unless (i + j).even?

    Rating.find_or_create_by!(user: rater, post: post) do |rating|
      rating.score = ((i + j) % 5) + 1
    end
  end
end

puts "Seeded #{User.count} users, #{Post.count} posts (#{Post.deleted.count} soft-deleted), #{Rating.count} ratings."
puts "All users share the password: #{SEED_PASSWORD}"
