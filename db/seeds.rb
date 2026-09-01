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

# A handful of real, topical posts (as opposed to the generic Faker filler
# above) so features that depend on actual content - full-text search and
# JSONB metadata - have something genuine to demonstrate out of the box.
# `GET /api/v1/posts/search?q=rails` or `Post.with_metadata("tags" => [
# "postgres"])` return nothing interesting against Faker::Lorem text; they
# do against this.
REALISTIC_POSTS = [
  {
    username: "alice",
    title: "Getting Started with Rails 8 and PostgreSQL",
    tags: %w[rails postgres ruby],
    body: "Rails 8 ships with Solid Queue and Solid Cache built in, but I'm " \
          "still reaching for Sidekiq and Redis on this project - mostly for " \
          "the ecosystem and admin UI. PostgreSQL remains my default database " \
          "of choice: JSONB, full-text search, and materialized views cover " \
          "most of what used to require a separate search engine or cache layer."
  },
  {
    username: "alice",
    title: "Speeding Up Background Jobs with Sidekiq",
    tags: %w[sidekiq ruby performance],
    body: "Batching database writes instead of issuing one UPDATE per job made " \
          "the biggest difference by far. A self-perpetuating recurring job " \
          "with a Redis heartbeat, instead of a cron-based scheduler gem, kept " \
          "the dependency list small without giving up reliability across " \
          "worker restarts."
  },
  {
    username: "bob",
    title: "Why I Switched My Caching Layer to Redis",
    tags: %w[redis caching rails],
    body: "After outgrowing Rails' file-based cache store, I moved everything " \
          "to Redis - not just Rails.cache, but rate limiting and background " \
          "job queues too, each on its own logical database index so they " \
          "never cross-contaminate. The latency win alone was worth the migration."
  },
  {
    username: "bob",
    title: "Full-Text Search in PostgreSQL, No Extra Services Required",
    tags: %w[postgres search],
    body: "A generated tsvector column and a GIN index handled search well " \
          "enough that Elasticsearch never made it onto the roadmap. " \
          "Weighting the title above the body with setweight made title " \
          "matches rank exactly where you'd expect them to."
  },
  {
    username: "carol",
    title: "A Weekend Hiking the Rockies",
    tags: %w[hiking travel outdoors],
    body: "Three days, forty miles, and one very sore pair of knees. The " \
          "trail above the tree line was still covered in late-season snow, " \
          "but the views over the valley made every switchback worth it. " \
          "Already planning next year's route."
  },
  {
    username: "carol",
    title: "Getting Better at Portrait Photography",
    tags: %w[photography],
    body: "Shooting wide open at golden hour solved more of my problems than " \
          "any lens upgrade did. The biggest lesson so far: move your feet " \
          "before you reach for the zoom ring."
  },
  {
    username: "dave",
    title: "My Go-To Sourdough Bread Recipe",
    tags: %w[cooking baking sourdough],
    body: "Feeding the starter twice a day for a week is the hardest part - " \
          "after that it's mostly patience. A long cold proof in the fridge " \
          "overnight gives the crumb an open, chewy texture, and a cast iron " \
          "dutch oven gets the crust properly crackling."
  },
  {
    username: "erin",
    title: "Notes on Remote Work Culture",
    tags: %w[remote-work culture],
    body: "The biggest adjustment wasn't the lack of an office - it was " \
          "learning to write things down instead of walking over to " \
          "someone's desk. Async communication forces clarity that a quick " \
          "hallway conversation never demanded."
  }
].freeze

users_by_username = users.index_by(&:username)

realistic_posts = REALISTIC_POSTS.map do |attrs|
  user = users_by_username.fetch(attrs[:username])

  Post.find_or_create_by!(user: user, title: attrs[:title]) do |post|
    post.body = attrs[:body]
    post.metadata = { "tags" => attrs[:tags] }
    post.created_at = rand(1..14).days.ago
    post.view_count = rand(50..500)
  end
end

posts += realistic_posts

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
puts 'Try: GET /api/v1/posts/search?q=rails (or postgres, redis, sidekiq, hiking, sourdough...)'
