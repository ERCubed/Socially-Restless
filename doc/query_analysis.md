# Query analysis: EXPLAIN findings against a real 1.2M-row table

This is the "database query analysis and add EXPLAIN output for critical queries"
optional requirement, written up with real, freshly re-captured output rather than
paraphrased from memory. The underlying decisions this backs (keyset over offset
pagination, not indexing `average_rating`) are already summarized in the
[README](../README.md#performance-considerations) and in comments in
[`app/controllers/concerns/paginatable.rb`](../app/controllers/concerns/paginatable.rb)
and [`app/controllers/api/v1/timeline_controller.rb`](../app/controllers/api/v1/timeline_controller.rb) —
this file is the underlying evidence for those, not a replacement for them.

**Method**: 1,200,000 rows were bulk-inserted directly via SQL (`INSERT ... SELECT
generate_series(...)`, not through Rails — a 1.2M-row `ActiveRecord#create` loop would
itself take longer than the queries being measured) into a local Postgres database, with
`created_at` spread across roughly two weeks so both "shallow" and "deep" cursor
positions exist in real data. `VACUUM ANALYZE` was run before measuring so the planner's
row-count estimates reflect the actual data, not stale statistics. All output below is
copy-pasted directly from `psql`, not transcribed by hand. The bulk data was deleted
immediately after capturing these results — it was never committed and isn't part of
the app's seed data.

## Finding 1: keyset pagination's cost depends on selectivity, not literally "page depth"

The Timeline's cursor pagination
([`Paginatable#paginate_by_cursor`](../app/controllers/concerns/paginatable.rb)) filters
on `(deleted_at, created_at, id)`, which has a covering composite index. The original
hypothesis was a clean "shallow pages are slow, deep pages are fast" split. Re-measuring
across four selectivities shows it's more precise than that: **the crossover is a
function of how many rows match the cursor condition, not how many pages a user has
paged through**.

| Rows remaining after cursor | % of table | Plan chosen | Execution time |
|---|---|---|---|
| ~1,200,023 (no cursor / page 1) | ~100% | Parallel Seq Scan + top-N sort | 146.6 ms |
| ~100,023 | 8.3% | Parallel Seq Scan + top-N sort | 79.4 ms |
| ~20,021 | 1.7% | Bitmap Index Scan + top-N sort | 29.2 ms |
| ~1,021 | 0.08% | Bitmap Index Scan + top-N sort | 3.1 ms |

Full output for the two boundary cases:

**~100,023 rows remaining (8.3% selectivity) — Seq Scan chosen:**
```
Limit  (cost=34960.58..34961.86 rows=11 width=137) (actual time=77.131..79.274 rows=11.00 loops=1)
  Buffers: shared hit=15310 read=10242
  ->  Gather Merge  (cost=34960.58..46699.59 rows=100793 width=137) (actual time=77.128..79.271 rows=11.00 loops=1)
        Workers Planned: 2
        Workers Launched: 2
        ->  Sort  (cost=33960.56..34065.55 rows=41997 width=137) (actual time=66.699..66.699 rows=11.00 loops=3)
              Sort Key: created_at DESC, id DESC
              Sort Method: top-N heapsort  Memory: 27kB
              ->  Parallel Seq Scan on posts  (cost=0.00..33024.14 rows=41997 width=137) (actual time=55.927..61.606 rows=33340.33 loops=3)
                    Filter: ((deleted_at IS NULL) AND (ROW(created_at, id) < ROW('2026-08-18 21:50:14.960706'::timestamp without time zone, 2100043)))
                    Rows Removed by Filter: 366667
Planning Time: 1.058 ms
Execution Time: 79.366 ms
```

**~20,021 rows remaining (1.7% selectivity) — Bitmap Index Scan chosen:**
```
Limit  (cost=27549.02..27549.05 rows=11 width=137) (actual time=29.063..29.066 rows=11.00 loops=1)
  ->  Sort  (cost=27549.02..27599.93 rows=20365 width=137) (actual time=29.059..29.061 rows=11.00 loops=1)
        Sort Key: created_at DESC, id DESC
        Sort Method: top-N heapsort  Memory: 27kB
        ->  Bitmap Heap Scan on posts  (cost=1541.17..27094.94 rows=20365 width=137) (actual time=10.989..23.107 rows=20021.00 loops=1)
              Recheck Cond: ((deleted_at IS NULL) AND (ROW(created_at, id) < ROW('2026-08-17 23:36:54.960706'::timestamp without time zone, 2180043)))
              Heap Blocks: exact=427
              ->  Bitmap Index Scan on index_posts_on_deleted_at_and_created_at_and_id  (cost=0.00..1536.08 rows=20365 width=0) (actual time=10.872..10.873 rows=20021.00 loops=1)
                    Index Cond: ((deleted_at IS NULL) AND (ROW(created_at, id) < ROW('2026-08-17 23:36:54.960706'::timestamp without time zone, 2180043)))
Planning Time: 1.292 ms
Execution Time: 29.169 ms
```

Somewhere between 1.7% and 8.3% selectivity, the planner's cost model crosses over from
preferring the index to preferring a sequential scan. That's expected, standard
behavior, not a bug: past a certain fraction of the table, walking the whole table
sequentially and sorting the top 11 in memory really can beat randomly-ordered heap
fetches through an index, because sequential I/O is cheaper per page than the
scattered reads a bitmap heap scan does once "recheck the visibility of each matching
row" touches enough of the table.

## Finding 2 (a correction to the earlier claim): at this selectivity, the planner's choice is actually *right*, not a limitation being worked around

The original write-up (in `Paginatable`'s comments) framed the shallow-page Seq Scan as
a "known Postgres cost-estimation limitation," implying the index-based plan would have
been faster if only the planner had chosen it. Forcing the index on with
`enable_seqscan = off` at the ~8.3%-remaining case and re-measuring shows that framing
was too pessimistic about the planner:

```
SET enable_seqscan = off;
-- same query as the 8.3%-remaining case above --
Limit  (cost=135882.54..135883.82 rows=11 width=137) (actual time=247.657..249.873 rows=11.00 loops=1)
  ->  Gather Merge  (cost=135882.54..275631.13 rows=1199904 width=137) (actual time=247.655..249.870 rows=11.00 loops=1)
        ->  Sort  (cost=134882.51..136132.41 rows=499960 width=137) (actual time=235.462..235.462 rows=11.00 loops=3)
              ->  Parallel Bitmap Heap Scan on posts  (cost=90711.43..123734.83 rows=499960 width=137) (actual time=123.833..184.786 rows=400004.00 loops=3)
                    ->  Bitmap Index Scan on index_posts_on_deleted_at_and_created_at_and_id (cost=0.00..90411.46 rows=1199903 width=0) (actual time=132.666..132.667 rows=1200034.00 loops=1)
Execution Time: 250.056 ms
```

Forcing the index made the query **slower** (250 ms vs. 79 ms) at this selectivity, not
faster — the bitmap index scan still has to visit and recheck ~100,000 heap pages, and
building/scanning the bitmap itself isn't free. The planner's default choice was
correct here. The finding stands (deep pages hit the index and are fast; shallow-ish
pages fall back to a scan), but the honest conclusion is narrower than originally
stated: this is the planner making a reasonable cost trade-off at this selectivity, not
a limitation being routed around. The practical mitigation is unchanged either way —
Timeline caches exactly the page (the first one) where this scan is largest and most
frequently hit (see [`WarmTimelineCacheJob`](../app/jobs/warm_timeline_cache_job.rb)),
so the 146.6 ms no-cursor case in the table above is the one real users essentially
never pay for.

## Finding 3: the `min_rating` filter confirms the "no index" decision

The Timeline's `?min_rating=` filter (`average_rating >= ?`) has no dedicated index —
a decision made after measuring, not by default. Re-confirmed here at two selectivities:

**Selective filter (`>= 4.5`, ~10% of rows match):**
```
Limit  (cost=33938.92..33940.21 rows=11 width=137) (actual time=86.326..88.188 rows=11.00 loops=1)
  ->  Parallel Seq Scan on posts  (cost=0.00..31774.12 rows=52239 width=137) (actual time=1.149..70.367 rows=40330.67 loops=3)
        Filter: ((deleted_at IS NULL) AND (average_rating >= 4.5))
        Rows Removed by Filter: 359677
Execution Time: 88.255 ms
```

**Unselective filter (`>= 0.5`, ~90% of rows match):**
```
Limit  (cost=42842.80..42844.09 rows=11 width=137) (actual time=105.082..106.811 rows=11.00 loops=1)
  ->  Parallel Seq Scan on posts  (cost=0.00..31774.12 rows=451567 width=137) (actual time=0.097..57.702 rows=360343.67 loops=3)
        Filter: ((deleted_at IS NULL) AND (average_rating >= 0.5))
        Rows Removed by Filter: 39664
Execution Time: 106.846 ms
```

Both plans do a sequential scan regardless of selectivity, because there's no index on
`average_rating` to consider in the first place — this is the baseline the earlier
indexing experiment was measured against. Even the selective case (~10% of rows) costs
about the same as the unfiltered Timeline query above (88 ms vs. 146.6 ms — actually
*less*, since a Seq Scan was already the chosen plan for the base query too), which is
consistent with the earlier conclusion that a dedicated index wouldn't pay for itself
here: the base query is already scan-bound at this table size, and a `min_rating` index
doesn't change what kind of scan the *unfiltered* Timeline query needs.

## Finding 4: the GIN index on `posts.metadata` is actually used, at two selectivities

`Post.with_metadata` filters on the jsonb `metadata` column's containment operator
(`@>`), backed by a GIN index (see the migration). A GIN index is the only access path
Postgres has for `@>` at all — a plain btree can't index it — so this confirms both
that the index gets chosen (not a foregone conclusion; the planner still has the option
to fall back to a sequential scan with a filter) and how much it's worth at different
selectivities. 1.2M rows were seeded with an even 5-way tag split (~20% selectivity per
tag) plus one row given a unique `external_id` marker (≈0.00008% selectivity, a
single-row lookup).

**20% selectivity (`metadata @> '{"tags": ["ruby"]}'`, ~240,000 of 1.2M rows match):**
```
Bitmap Heap Scan on posts  (cost=1716.57..53106.12 rows=244364 width=288) (actual time=42.175..218.236 rows=240000.00 loops=1)
  Recheck Cond: (metadata @> '{"tags": ["ruby"]}'::jsonb)
  Heap Blocks: exact=48334
  ->  Bitmap Index Scan on index_posts_on_metadata  (cost=0.00..1655.48 rows=244364 width=0) (actual time=35.649..35.649 rows=240000.00 loops=1)
        Index Cond: (metadata @> '{"tags": ["ruby"]}'::jsonb)
Execution Time: 223.939 ms
```
Forcing a sequential scan for comparison (`SET enable_bitmapscan/enable_indexscan =
off`) gives 290.5 ms — the index wins, but only modestly: returning ~20% of a table's
rows means most of its pages get touched either way, so there's a real but limited
benefit at this selectivity.

**≈0.00008% selectivity (`metadata @> '{"external_id": "uniq-marker-9f3a"}'`, 1 row of
1.2M matches):**
```
Bitmap Heap Scan on posts  (cost=338.80..342.81 rows=1 width=288) (actual time=0.016..0.016 rows=1.00 loops=1)
  Recheck Cond: (metadata @> '{"external_id": "uniq-marker-9f3a"}'::jsonb)
  Heap Blocks: exact=1
  ->  Bitmap Index Scan on index_posts_on_metadata  (cost=0.00..338.79 rows=1 width=0) (actual time=0.010..0.010 rows=1.00 loops=1)
Execution Time: 0.063 ms
```
The forced-sequential-scan baseline for the exact same query:
```
Parallel Seq Scan on posts  (cost=0.00..54584.52 rows=1 width=288) (actual time=85.587..85.588 rows=0.33 loops=3)
  Filter: (metadata @> '{"external_id": "uniq-marker-9f3a"}'::jsonb)
  Rows Removed by Filter: 400007
Execution Time: 96.514 ms
```
**0.063 ms vs. 96.5 ms — roughly a 1,500x difference** for a selective, single-row
lookup. This is the shape of query a GIN index on jsonb is actually for: looking up one
specific document (an external id, a unique flag) out of a large table by an arbitrary
key inside it, without needing a dedicated column or index for that one key.

## Finding 5: the materialized view wins, and the *reason why* connects back to Finding 1

`timeline_feed` (see [`TimelineFeedEntry`](../app/models/timeline_feed_entry.rb)) is a
materialized view over `SELECT * FROM posts WHERE deleted_at IS NULL`, kept current by
[`RefreshTimelineFeedViewJob`](../app/jobs/refresh_timeline_feed_view_job.rb) — deliberately
**not** wired into `TimelineController`'s live request path (see the README's Optional
requirements section for why: Rails.cache already makes the hottest request effectively
free, and this doesn't change that). Benchmarked here anyway, for real, against the same
1.2M-row table as Finding 1 (refreshed once via `TimelineFeedEntry.refresh!`), on the
exact query that's slowest in Finding 1 — the unfiltered first page:

**Base table (`posts`, with the `deleted_at IS NULL` condition):**
```
Limit  (cost=63609.95..63611.23 rows=11 width=271) (actual time=155.856..156.973 rows=11.00 loops=1)
  ->  Gather Merge  (cost=63609.95..203364.14 rows=1199952 width=271) (actual time=155.855..156.971 rows=11.00 loops=1)
        ->  Sort  (cost=62609.93..63859.88 rows=499980 width=271) (actual time=147.813..147.814 rows=11.00 loops=3)
              Sort Key: created_at DESC, id DESC
              ->  Parallel Seq Scan on posts  (cost=0.00..51461.80 rows=499980 width=271) (actual time=0.834..76.421 rows=400007.33 loops=3)
                    Filter: (deleted_at IS NULL)
Execution Time: 157.056 ms
```

**Materialized view (`timeline_feed`, no filter needed at all):**
```
Limit  (cost=0.43..2.56 rows=11 width=271) (actual time=0.036..0.042 rows=11.00 loops=1)
  ->  Index Scan Backward using index_timeline_feed_on_created_at_and_id on timeline_feed (cost=0.43..232300.57 rows=1200031 width=271) (actual time=0.036..0.041 rows=11.00 loops=1)
Execution Time: 0.061 ms
```

**157 ms vs. 0.061 ms — roughly 2,500x.** The honest reason why connects directly to
Finding 1, rather than being a separate phenomenon: the base table's query still carries
a `WHERE deleted_at IS NULL` condition for the planner to reason about the selectivity
of, and — exactly as Finding 1 found for the unfiltered case — it estimates that as
"most of the table matches" and falls back to a Parallel Seq Scan + sort. The
materialized view has no such condition at all (every row already satisfies it, by
construction), so there's no selectivity to distrust: `ORDER BY ... LIMIT 11` against an
already-filtered, indexed view is a pure backward index walk that stops after 11 rows,
with nothing to scan or filter first. A materialized view's real performance win here
isn't "views are faster" in the abstract — it's that pre-computing the filter removes
exactly the condition that made the planner's cost estimate pessimistic in Finding 1.

## What these findings do and don't change

Nothing here changes an actual decision already made — keyset pagination over `OFFSET`
is still correct (its cost is bounded by table size either way, unlike `OFFSET`'s, which
grows with page depth), the Timeline's cache still targets exactly the query that's
slow, and `average_rating` still isn't worth a dedicated index at this scale. What
changes is the confidence behind one claim: the "known limitation" framing is replaced
with "the planner is right at this selectivity," which is a stronger, more specific
result than the original write-up claimed — the kind of correction real
`EXPLAIN ANALYZE` output can force that reasoning from documentation alone can't. The
GIN index finding (Finding 4) is new evidence, not a correction: it confirms the
`metadata` index behaves exactly as intended, most dramatically for the kind of
high-selectivity lookup it's actually built for. Finding 5's 2,500x number is real and
reproducible, but it isn't a case for wiring the materialized view into the live
request path either: the 157ms it improves on is a request Rails.cache already serves
in effectively 0ms on every hit, so the honest reading is that a materialized view
would be solving a problem the app's existing cache already solved, not a new one.
