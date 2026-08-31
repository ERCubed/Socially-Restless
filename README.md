# Socially Restless

A RESTful JSON API for a social media application: user accounts, posts, a
1-5 star rating system, and an activity timeline — built as a Rails Code
Challenge submission with a focus on API design, performance at scale, and
concurrency correctness.

## Tech stack

- **Ruby** 3.4.10, **Rails** 8.1 (API-only)
- **PostgreSQL** — primary datastore
- **Redis** — backs rate limiting and the Timeline cache (via `:redis_cache_store`)
- **RSpec** — the entire test suite is request/model specs; no controller/view specs
- Key gems and why: 
  - `bcrypt` (password hashing)
  - `rack-attack` (rate limiting)
  - `redis` (cache/rate-limit backend)
  - `rspec-openapi` (API docs generated from the request specs themselves)
  - `simplecov` (enforced coverage minimum)

Deliberately *not* in the stack: Action Mailer, Action Cable, Active Storage, and Minitest
were all removed from `config/application.rb` rather than left unconfigured — this app
sends no email, has no WebSocket features, stores no uploads, and tests exclusively with
RSpec, so there was no reason to keep those frameworks loaded.

## Setup

### Prerequisites

- Ruby 3.4.10 (see `.ruby-version` — works with rbenv/rvm/asdf)
- PostgreSQL running locally
- Redis running locally

### Install

```bash
bundle install
bin/rails db:create db:migrate
bin/rails db:seed   # optional, but recommended - see "Seed data" below
```

Redis needs to be reachable at `redis://localhost:6379` for both caching and rate limiting
to work in development (see [Environment variables](#environment-variables) below if
yours runs elsewhere). If Redis isn't available, the app **does not crash** — see
[Graceful Redis degradation](#graceful-redis-degradation) — but rate limiting and caching
will be effectively disabled.

### Run it

```bash
bin/rails server
```

### Run the tests

```bash
bundle exec rspec
```

This runs the full suite (request specs for every endpoint, model specs, and a live-Redis
rate-limiting spec) and enforces a **70% minimum line coverage** gate via SimpleCov — the
run fails (non-zero exit) if coverage drops below that, not just reports a number. A
coverage report is written to `coverage/index.html`.

### Seed data

`bin/rails db:seed` creates 5 users (`alice`, `bob`, `carol`, `dave`, `erin`), a spread of
posts per user (one deliberately soft-deleted), and a deterministic set of cross-ratings
so `average_rating`/`ratings_count` show real variety out of the box. It's idempotent —
safe to run repeatedly against the same database without creating duplicates.

Every seeded user shares the password `password123`, so you can log in as any of them
immediately:

```bash
curl -X POST http://localhost:3000/api/v1/session \
  -H "Content-Type: application/json" \
  -d '{"session":{"email":"alice@example.com","password":"password123"}}'
```

### Environment variables

| Variable | Used for | Default if unset |
|---|---|---|
| `REDIS_URL` | `Rails.cache` backend (dev/prod) | `redis://localhost:6379/0` (dev only; **required** in production, no fallback) |
| `RAILS_MASTER_KEY` | Decrypting `config/credentials.yml.enc` in production | — |

Development and test deliberately use **different Redis DB indices** for both the cache
and rate-limit counters (dev: 0/2, test: 1/3), the same way they already have separate
Postgres databases — so running the app and running the test suite locally at the same
time can't cross-contaminate each other's cached/throttled state.

### Docker

`Dockerfile` builds a production image (see the comment at its top for `docker build`/`run`
usage with Kamal or by hand). It's not used for local development — use the steps above
for that.

## API documentation

Full endpoint documentation (request/response schemas, status codes, real examples) is
generated from the request spec suite itself, not hand-written — see
[How the docs stay accurate](#how-the-docs-stay-accurate) below. Three ways to read it:

1. **Browse it**: start the server, visit `http://localhost:3000/api-docs`
2. **Raw file**: [`doc/openapi.yaml`](doc/openapi.yaml) — a standard OpenAPI 3 document,
   importable into Postman, Redoc, Swagger UI, or any OpenAPI-aware tool
3. **Quick reference** — every endpoint, at a glance:

| Method | Path | Auth | Description |
|---|---|:---:|---|
| `POST` | `/api/v1/users` | – | Register a new user; returns a session token |
| `POST` | `/api/v1/session` | – | Log in; returns a session token |
| `DELETE` | `/api/v1/session` | – | Log out (revokes the presented token, if any) |
| `GET` | `/api/v1/users/:username/posts` | – | One user's posts, paginated (`page`/`per_page`) |
| `POST` | `/api/v1/posts` | ✓ | Create a post |
| `GET` | `/api/v1/posts/:id` | – | View a post |
| `DELETE` | `/api/v1/posts/:id` | ✓ (owner) | Soft-delete a post |
| `POST` | `/api/v1/posts/:post_id/rating` | ✓ | Rate a post 1-5 (create or update your own rating) |
| `GET` | `/api/v1/timeline` | – | Recent posts from all users, paginated (`cursor`/`per_page`), filterable (`min_rating`) |

All responses use a consistent error envelope on failure:

```json
{ "error": { "message": "Validation failed", "details": ["Score is not included in the list"] } }
```

### How the docs stay accurate

`doc/openapi.yaml` is generated by [rspec-openapi](https://github.com/exoego/rspec-openapi)
from the request specs — it records the *actual* requests/responses each spec produces, so
the documented schemas and status codes can't drift from what the code really does the way
hand-maintained docs can.

- Regenerate locally after changing an endpoint: `OPENAPI=1 bundle exec rspec`
- CI regenerates it on every run and fails the build if the committed file is
  out of date (`bin/rails openapi:verify`, in `.github/workflows/ci.yml`) — comparing
  structurally (paths, schemas, status codes), not byte-for-byte, since the recorded
  `example:` values (Faker names, ids, timestamps) are never identical between two runs
  of identical code by design.

So: add an endpoint, write its request spec (which you'd do anyway), and the docs are
"all good to go" the next time the suite runs with `OPENAPI=1` — no separate annotation
step to remember.

## Architectural decisions and trade-offs

**Authentication: DB-backed sessions, not JWT.** Registration/login return an opaque
bearer token backed by a `sessions` row (`Session.start!`/`Session.authenticate`), with
only the token's SHA-256 digest stored — never the raw token. A JWT would need extra
infrastructure (a denylist) to support real revocation before expiry; a DB-backed session
can just be deleted outright — `DELETE /api/v1/session` really does log you out
immediately, verified by confirming the token stops authenticating afterward, not just
returning `204`.

**Soft deletion without a `default_scope`.** Posts use a `deleted_at` timestamp and
`Post.kept`/`Post.deleted` scopes, not a `default_scope` that hides deleted rows
everywhere. A `default_scope` would need `.unscoped` to escape it and tends to produce
surprising behavior for anyone who forgets it's there; explicit scopes mean a soft-deleted
post stays reachable on purpose (e.g. for a future admin/audit view) instead of silently
invisible everywhere by default.

**Two different pagination strategies, deliberately.** `GET /api/v1/users/:username/posts`
uses ordinary offset pagination (`page`/`per_page`, exact `total_count`); `GET
/api/v1/timeline` uses keyset/cursor pagination (`cursor`/`per_page`, `has_more`/
`next_cursor`, no total count). This isn't inconsistency — it's matching the strategy to
the data shape. A single user's posts is a small, bounded dataset where "jump to page 3"
is genuinely useful UX and `OFFSET`'s cost never gets deep enough to matter. The Timeline
is the opposite: unbounded, all-users, potentially 1M+ rows, where `OFFSET`'s cost grows
without bound the deeper you page — and, separately, `OFFSET` pagination is outright
*incorrect* on a table that's constantly getting new rows (a post inserted between two
page requests shifts every row's position, causing skipped or duplicated results). Keyset
pagination has neither problem, at the cost of no arbitrary page-jump and no exact count
— an accepted trade for a scroll-style feed (this is how GitHub's and Stripe's list APIs
work too).

**Rating stats are cached, not computed live — and made concurrency-safe on purpose.**
`posts.average_rating`/`ratings_count` are denormalized columns, recomputed fresh (not
incrementally) from `ratings` on every write via `Post#recalculate_rating_stats!`, so
reading a post never runs a live `AVG()`/`COUNT()`. `Rating.rate!` wraps the whole
find-or-update-rating-and-recalculate-stats sequence in one transaction with an explicit
row lock (`post.lock!`) taken *before* touching the `ratings` table. That lock closes two
real races at once: two concurrent first-time raters both passing a "does a rating already
exist?" check before either commits (which would otherwise hit the DB's unique constraint
and blow up), and two concurrent stats recalculations each computing an average from a
snapshot that's missing the other's not-yet-committed rating (a classic lost update). This
wasn't just reasoned about — it was verified with two genuinely separate OS processes
racing to rate the same post simultaneously, confirming zero overlap between their critical
sections and the exact correct final average.

**Rate limiting fails open, verified by actually killing Redis.** `Rack::Attack` uses its
own dedicated Redis connection (not shared with `Rails.cache`, which is `:null_store` in
development by default) so throttling doesn't silently do nothing depending on an
unrelated dev-cache toggle. It's backed by `ActiveSupport::Cache::RedisCacheStore`
specifically because every operation on that store is wrapped in a rescue that logs and
falls back rather than raising — so a Redis outage disables rate limiting instead of
`500`-ing every request. Confirmed by literally stopping `redis-server` mid-session and
watching requests keep succeeding normally.

**Consistent error envelope everywhere.** Every error path — validation failures, 404s,
401s, malformed params, rate-limit rejections — renders `{ "error": { "message",
"details" } }` via one shared helper (`ApplicationController#render_error`), including a
custom `rack-attack` responder so even a `429` looks like every other error this API
returns rather than a plain-text one-off. 404s deliberately don't include
`ActiveRecord::RecordNotFound`'s default message, which embeds the failed SQL `WHERE`
clause — internal detail that shouldn't leak to a client.

## Performance considerations

**Indexes for every query this app actually makes**: a composite `(deleted_at,
created_at, id)` index on `posts` (soft-delete filtering + recency sort + keyset
tiebreaker, all from one index instead of three), a unique `(user_id, post_id)` index on
`ratings` (both the uniqueness guarantee *and* the lookup path for
`find_or_initialize_by`), unique indexes on `users.username`/`users.email`, and an index
on `sessions.token_digest` for the auth lookup that runs on every authenticated request.

**Query design was verified against a real 1M+ row table, not assumed.** The Timeline's
cursor pagination was benchmarked with `EXPLAIN ANALYZE` against a seeded 1.2M-row `posts`
table before being trusted. That surfaced a real, non-obvious finding: Postgres sometimes
chooses a full sequential scan over the covering index for a *shallow* cursor page (e.g.
"page 2" of a feed, where nearly the whole table still matches "older than this") — a
known Postgres cost-estimation limitation for this query shape, not a missing index. Three
different query rewrites were tried and none changed the plan. The mitigating fact, also
verified: that cost is bounded by table size and only affects the first few pages —
exactly the case the Timeline's caching (below) already eliminates — unlike `OFFSET`
pagination, whose cost is unbounded and grows with depth. This reasoning (and the decision
*not* to add a dedicated index for the `min_rating` filter after measuring it — an index
made the selective case *slower* in one real test, due to cache-state effects, and
couldn't help the required sort regardless) is documented inline in
`app/controllers/concerns/paginatable.rb` and `app/controllers/api/v1/timeline_controller.rb`.

**Timeline caching**: only the first page (no `cursor`) is cached, for 30 seconds, keyed
on `per_page`/`min_rating`. That's deliberate, not partial — the overwhelming majority of
Timeline traffic is "show me the latest posts," so caching just that is a small, bounded
keyspace with a high hit rate, unlike caching every cursor value (mostly single-use
entries, poor hit rate). A flat TTL instead of active invalidation on every post/rating
write is the "basic" half of "basic caching strategy" — up to 30s of staleness is an
ordinary, accepted tradeoff for a social feed, and it avoids coupling `Post`/`Rating`
writes to Timeline's cache keys.

**N+1 prevention is asserted, not assumed.** The Timeline eager-loads authors
(`.includes(:user)`); a request spec subscribes to `sql.active_record` notifications and
asserts exactly 2 `SELECT`s fire regardless of how many distinct authors are on the page,
so a future change that accidentally reintroduces an N+1 fails a test, not just a code
review.

**Rate limiting** protects the whole API from abuse (300 req/5min per IP) with much
tighter limits on login and signup specifically (5 req per 20s/60s per IP) — the classic
brute-force/credential-stuffing/spam-signup targets.

## Optional requirements

## Testing

- `bundle exec rspec` — full suite, request specs for every endpoint plus model specs
- 70% minimum coverage enforced via SimpleCov (fails the run if not met)
- A dedicated spec exercises rate limiting against a **real** Redis instance (not mocked),
  temporarily enabling `Rack::Attack` (off by default in test) and resetting its counters
  around each example
- `OPENAPI=1 bundle exec rspec` additionally regenerates `doc/openapi.yaml`

CI (`.github/workflows/ci.yml`) runs Brakeman (security static analysis), Rubocop
(style), the full test suite against real Postgres and Redis service containers, and the
OpenAPI freshness check, on every push and PR.
