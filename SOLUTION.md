# Socially Restless - The Approach

![Socially Restless Title](.github/assets/socially_restless.jpg)

## Why Socially Restless?

A good question, and one that ultimately has a twisted answer. 

This was a basic social site driven entirely by RESTful APIs. And social media
tends to make people more restless thanks to continuous doom-scrolling.

So why not a tongue-in-cheek name that sounds like it's all GraphQL, 
but is just REST and JSON?

Seriously. That was the thought process.

## Approach to Requirements

Requirements were reviewed in full and determined to be in both a priority as well as logical order, and were tackled as such with a few caveats such as creating both page and cursor-based pagination (which allowed for solid performance testing with an AI-generated 1.2M row table to determine best options).

### User Management

The plan was to keep it simple and small. No sense in making a huge `User` model when it's not needed. Focused on ensuring passwords were hashed properly and validation errors did not reveal too much information.

Initially looked at JWT for the authentication, but settled on a simple Bearer token. See the main [README.md](README.md) for details.

### Posts

Again, keep it small and simple. Ensure that things can be soft deleted, but that scopes (or lack of default scopes) makes sense in the grander scheme of what could be built.

Pagination took a bit of a detour as I looked at per-page and cursor based, and asked AI for assistance with both in determining which would be best. In the end, settled on per-page for the User's `Post` endpoint as the numbers would more than likely not be massive (While I'm not a prolific posting machine on Facebook, I've only made 1600 posts in 10+ years. Even a highly active friend has only 24,000 posts in a similar time frame. Neither being huge performance burdens for per-page pagination.) The cursor based pagination was held on to for upcoming work on the Timeline.

View count was another bit of a challenge. Not because of implementation issues, but rather determining what constituted a view. This generated a nice long "discussion" with Claude over how other platforms determined if a post was viewed or not. This ultimately turned in to "what's the difference between a viewed post and an engaged post?" The final solution implements "views" more as intentional "engagements" when a User intentionally views a single Post, or another User's feed. As everything was already named regarding `views` by the time Claude and I came to a consensus, I left the naming convention alone.

The implementation itself went through a few stages. It started as a simple loop, issuing one `UPDATE` per post as its view was recorded - functional, but obviously not going to hold up under real concurrent traffic on a popular post. With a nudge from Claude I changed it to a bulk update based on an array of IDs instead - one database statement touching multiple rows is better than a lookup and update per row. Later, once Sidekiq was in the mix for the optional requirements, we went a step further: views are now recorded as Redis counters on the request path, with `FlushViewCountsJob` periodically batching the accumulated deltas into a single `UPDATE` against Postgres every 30 seconds. A popular post being viewed thousands of times no longer touches the database at all on the hot path - the counter just increments in Redis, and the eventual Postgres write stays a small, bounded, infrequent operation no matter how much traffic the post is actually getting.

### Rating System

Right off I knew that `find_or_initialize_by` was the way to go. Removing a rating was purposefully left out to make things a little simpler to process. Caching of the average ratings is stored in a field on the row, making it a simple data point pulled with the rest of the `Post`. If things go awry, the same row-locking `Post#recalculate_rating_stats!` method which handles the calculation can be called manually to set things right with a recalculation.

### Activity Timeline

This was a relatively straightforward addition, behaving just like a User's feed except that it was not filtered by User, and that it used cursor based pagination. Adding in the minimum average filtering was straightforward. Discussions with Claude tweaked it with some caching for better eager loading capabilities.

### API Design

This was kept in mind throughout development. Amusingly, I had planned on route versioning `/api/v1/...` before even getting to this section. Claude was used to ensure that proper HTTP codes were used everywhere after years of my dealing with GraphQL's `Status 200: Successful Error`. 

Claude was consulted again as to how to best implement rate limiting as most systems I've worked on already had rate limiting implemented before I arrived on the scene. The `rack-attack` gem was determined the best solution for this scenario, and implemented. (If I'm going to stub something, I may as well implement it.)

### Testing and Documentation

This is one area where I decided to rely heavily on AI to help me move faster. Allowing it to write RSpec tests for me helped to catch edge cases quickly as well as not spending time on writing a lot of boilerplate type tests that you know are needed but can be somewhat repetitive. Claude ran in the background writing tests as I wrote some of the code. 

Claude was also used to write a bulk of the [README.md](README.md) file and document decisions in the code itself. Those code decisions are why there are some rather large comments in this codebase as I have a standing rule for it to document our decisions and make TODO notes as I go along for all of my projects. 

As a side note: These comments are more the style for my personal projects as I don't have other developers that I need to share information with. For those real-world, real job, cases I move them into a wiki page as development progresses.

### Performance Considerations

From the start, I planned on indexing searched and filtered columns to assist with performance. To ensure things were optimized for large scale datasets, Claude was asked to ramp the system up to 1.2M rows of data in the `Post` model. It was kept basic with just the five seed users as the focus was performance over the `Post` model and `User` is as indexed and optimized as its basic functionality needs at this time.

### AI Usage

As expected, and mentioned as allowed, AI assistance was used with pair-programming with Claude. Directions and guidance was given as each step. This was not a case of every task turning in to "build this for me, I don't care" but a careful and deliberate discussion of pros and cons of different techniques as needed along with concurrent programming (ie: While I add a new model endpoint, please build the associated serializer.)

Deeper AI leverage was engaged with some of the caching and database optimization items. I will be honest in that I will sometimes miss a more performant pattern with caching choices. I have also almost always had a DBA or other database expert to rely on when projects required extra focus on database optimization.

Claude was also used to build and run the performance tests which were able to be run in the background as development progressed in other areas.

## Challenges Faced

The biggest challenge faced was constantly overthinking the solutions. I would find myself trying to optimize areas that didn't necessarily need it, or question multiple ways to do something (such as the average rating calculation). During those times I would fall back to Claude as I would fall back to a teammate to rubber duck the ideas and get back on to track.

Smaller challenges and solutions are mentioned above.

## Do Differently

The big thing I would do differently is add GraphQL to the mix, especially given how I named the project. But focusing on REST, as the project required, was the right choice.

Given more time I would probably also research more pre-built gems before just diving in. For example, there may be a better rate limiting solution than `rack-attack`, even though it's an industry standard. Ensuring that it has the flexibility needed for the issues we're solving for (in this case, it appears to be good) without being overkill or a pain to implement and manage.

Logging. I'd be logging more to ensure that decisions made are the correct ones (ie: are we rate limiting enough or too much?)

Services. A lot of the shared code in here is currently sitting in modules in the `lib` directory. It works, but I'd probably rename and move at least some of them into services. I'd also add a `NotificationService` which would allow for easier pushing of information into logs as well as any monitoring systems that would be used in a production level system. Another `UserNotificationService` would be made to handle communications out to the user, including their preferred way of receiving things (email, sms, smoke signal, etc.)

There is currently no way for a user to delete their account. I know it's not in the specs, but years of HIPAA and GDPR make me cringe some when there's not a way. I'd add a way to soft delete the account with a job to then anonymize the data after a predetermined time.

## Performance Benchmarks

Claude was used to run performance metrics, in particular against the `posts` table. Full details and methodology are in [query_analysis.md](doc/query_analysis.md) with a summary below.

### Benchmark results (1.2M-row `posts` table)

All queries measured with real `EXPLAIN ANALYZE` output.

#### Timeline cursor pagination — cost tracks selectivity, not page depth

| Rows remaining after cursor | Selectivity | Plan chosen        | Time     |
|---|---|---|---|
| ~1,200,023 (no cursor / page 1) | ~100% | Parallel Seq Scan + sort | 146.6 ms |
| ~100,023 | 8.3% | Parallel Seq Scan + sort | 79.4 ms |
| ~20,021 | 1.7% | Bitmap Index Scan + sort | 29.2 ms |
| ~1,021 | 0.08% | Bitmap Index Scan + sort | 3.1 ms |

Forcing the index on at the 8.3% case (`enable_seqscan = off`) measured **250 ms** —
slower than the planner's own choice (79 ms). The planner is making the right call at
that selectivity, not exhibiting a limitation.

#### `min_rating` filter — no dedicated index (a measured decision, not an oversight)

| Filter | Selectivity | Plan | Time |
|---|---|---|---|
| `average_rating >= 4.5` | ~10% match | Seq Scan | 88.3 ms |
| `average_rating >= 0.5` | ~90% match | Seq Scan | 106.8 ms |

#### JSONB `metadata` containment (`@>`), GIN-indexed

| Query | Selectivity | Indexed (Bitmap Index Scan) | Forced Seq Scan | Speedup |
|---|---|---|---|---|
| `{"tags": ["ruby"]}` | ~20% match | 223.9 ms | 290.5 ms | ~1.3x |
| `{"external_id": "..."}` | 1 row of 1.2M | **0.063 ms** | 96.5 ms | **~1,500x** |

#### Materialized view (`timeline_feed`) vs. base table — unfiltered first page

| Source | Plan | Time |
|---|---|---|
| `posts` (with `deleted_at IS NULL`) | Parallel Seq Scan + sort | 157.1 ms |
| `timeline_feed` (pre-filtered, no condition to distrust) | Index Scan Backward | **0.061 ms** |

**~2,500x.** Not because materialized views are inherently faster — because the view
has no `deleted_at` condition left for the planner to distrust (same phenomenon as the
pagination finding above, from the other direction). Deliberately not wired into the
live Timeline path: the 157 ms it improves on is a request `Rails.cache` already serves
in ~0 ms on every hit.
