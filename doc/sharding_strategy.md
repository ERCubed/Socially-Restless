# Database sharding strategy

Not implemented. This is a design exercise for the "explain the approach even if not
fully implemented" optional requirement — the reasoning below explains both a plausible
approach and, more importantly, why this specific schema makes horizontal sharding
harder than it first looks, and why it isn't the right next scaling lever for this app
today.

## Why this isn't implemented (and arguably shouldn't be, yet)

Sharding solves a problem this app doesn't have: a single Postgres primary that can no
longer hold the data or absorb the write volume. The Performance considerations section
of the [README](../README.md) measured this app's actual bottleneck at 1M+ rows with
real `EXPLAIN ANALYZE` output — a single, well-indexed Postgres instance handles it
fine (single-digit-millisecond queries, see [`query_analysis.md`](query_analysis.md)).
Sharding trades that simplicity for real, permanent complexity (cross-shard joins,
cross-shard transactions, rebalancing, a routing layer) — a cost worth paying only once
a single primary is actually the constraint, typically at 10-100x this app's current
scale, or when write throughput (not just data size) exceeds one primary's capacity. The
realistic *next* lever before sharding is read replicas for read-heavy traffic (Timeline,
post listings), which this app doesn't have yet either — see "A more realistic next
step" below.

## Choosing a shard key: `user_id`

If/when sharding became necessary, `user_id` is the natural key: it's present (directly
or via `post_id`) on every table that matters (`users`, `sessions`, `posts`, `ratings`),
and it's the axis most reads and writes already filter on (a user's own posts, a user's
session lookups). Consistent hashing over `user_id` (rather than a fixed range) avoids
hot shards from sequential id assignment and makes adding shards later a matter of
re-hashing a fraction of users rather than re-partitioning everything.

Tooling: Rails has had native horizontal sharding support since 6.1/7 —
`config/database.yml`'s `shards:` key, `connects_to shards: { shard_one: {...}, ... }`
on a base class, and `ActiveRecord::Base.connected_to(shard: ...)` to route a block of
code to a specific physical database. For a monolith of this shape, that's the right
tool over something like Citus (distributed Postgres) or a foreign-data-wrapper
approach — it keeps every shard a plain, boring Postgres database, and the routing
logic lives in application code that's easy to reason about and test, rather than in a
separate distributed-systems layer that has to be operated and debugged on its own.

## What shards cleanly

`users` and `sessions` shard cleanly on `user_id` (a session belongs to exactly one
user, full stop). Every session lookup (the bearer-token digest check that runs on
*every* authenticated request) becomes a single-shard read the moment the request's
`user_id` is known — no cross-shard fan-out for the highest-QPS query in the app.

## What doesn't: `ratings` cross a shard boundary that `posts` alone don't

A `Post` naturally shards with its author. A `Rating`, though, has *two* user
relationships: the rater (`rating.user_id`) and, transitively through `rating.post`, the
post's author. Sharding by `user_id` puts the rating on the rater's shard, but the post
it references — and the `posts.average_rating`/`ratings_count` counters it has to
update — can live on a *different physical database* than the shard the rating itself
would be written to.

That's not a minor inconvenience — it breaks the actual correctness mechanism
[`Rating.rate!`](../app/models/rating.rb) depends on today. That method wraps the
upsert and the stats recalculation in one Postgres transaction, made safe by `post.lock!`
(`SELECT ... FOR UPDATE`) inside it — verified in this codebase with two genuinely
separate OS processes racing to rate the same post. A single ACID transaction, and a
single row-level lock, only work within one Postgres instance. If the rating and the
post it locks live on different shards, that guarantee is gone; the honest replacement is
a much heavier mechanism — a two-phase commit, a saga with a compensating rollback step,
or an outbox pattern — for what is currently a five-line, fully-consistent transaction.
Trading a correct, verified, simple mechanism for a distributed one *is* the real cost
of sharding this table, not an implementation detail to wave past.

Three ways to actually resolve this, in order of how much they preserve today's
guarantees:

1. **Don't shard `posts`/`ratings` at all — shard only `users`/`sessions`.** Keep post
   and rating data on a single, unsharded "content" database. This is the honest
   "shard what's actually easy, leave what isn't" answer: it gets the highest-QPS table
   (session auth) off the primary without touching `Rating.rate!`'s correctness
   mechanism at all. Content growth is handled by read replicas and indexing instead
   (see below), not by sharding.
2. **Shard posts/ratings by the** ***post's*** **author, and accept cross-shard writes
   for ratings.** A rating is written to the same shard as the post it rates (not the
   rater's shard), which keeps `post.lock!` single-shard and correct. The cost moves
   to reads: "show me all ratings a given user has made" (not a current endpoint, but a
   plausible future one) now has to fan out across every shard instead of hitting one.
3. **Shard by post author and rebuild `Rating.rate!` as a saga.** Keeps the rater-owned
   write local to the rater's shard; the stats update on the post's shard becomes a
   second step with its own compensating action if it fails. This is the most
   "textbook distributed systems" answer and the most expensive to build and operate —
   worth it only if option 2's cross-shard read pattern turns out to be a real,
   frequent access path, not a hypothetical one.

Given the actual access patterns this app has today, option 1 is the pragmatic choice
if sharding were ever forced by session-table volume specifically; options 2/3 are the
honest answer if post/rating volume itself became the bottleneck instead.

## The Timeline makes this worse: a global feed doesn't have a shard key

Every scheme above optimizes for "operations scoped to one user." The Timeline endpoint
is the opposite by design — "recent posts across all users" has no `user_id` to route
on, so a sharded `posts` table turns it into a scatter-gather query: fan out the same
`ORDER BY created_at DESC LIMIT n` to every shard, then merge-sort the per-shard results
in the application. That's a real, working pattern (and each shard's local query stays
cheap — it's the same covering-index query already verified in this repo, just against
1/N as many rows) — it just adds real latency (the request has to wait for the *slowest*
shard) and application-level merge logic that doesn't exist today.

The more scalable long-term answer, and the one that composes naturally with
infrastructure this app already has: a **fan-out-on-write feed table**, populated by a
Sidekiq job at post-creation time (the same pattern already used for
[`FlushViewCountsJob`](../app/jobs/flush_view_counts_job.rb) and
[`WarmTimelineCacheJob`](../app/jobs/warm_timeline_cache_job.rb)), living on its own
unsharded database dedicated to feed reads. Every new post enqueues a job that appends
a denormalized row (post id, author id, created_at, and whatever's needed to render a
feed entry without a join) to that table — the Timeline then reads from one place, no
scatter-gather, regardless of how many shards `posts` itself lives on. This is the
standard shape large-scale feed systems (Twitter's original fan-out design is the
canonical example) converge on precisely because "recent activity across everyone" and
"per-user sharding" pull in opposite directions.

## A more realistic next step, before any of this

If read load on `posts`/`ratings` actually became the bottleneck, a Postgres read
replica (or several, behind Rails' built-in `connects_to` read/write splitting) handles
the Timeline/post-listing read traffic this app is dominated by, without touching
correctness at all — reads that don't need up-to-the-millisecond freshness (which the
Timeline already accepts, via its 30s cache) go to a replica, writes stay on the
primary, and `Rating.rate!`'s single-database transaction is completely unaffected.
That's a much smaller change, with a much smaller blast radius, than sharding — and the
kind of thing worth doing well before sharding becomes necessary at all.
