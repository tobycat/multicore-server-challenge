# Assembly / gather

Front: direct

A Conduit (RealWorld) API server written entirely in x86-64 assembly: GNU `as` with `.intel_syntax noprefix`, linked
statically with `ld`, no libc, raw Linux syscalls only. The HTTP/1.1 server, Postgres wire protocol (SCRAM-SHA-256,
extended query), JSON, HS256, bcrypt and gzip are all in `src/`. GNU binutils, PostgreSQL 18.

```
./install.sh     # once, as root: installs binutils
./build.sh       # assembles src/*.s and links ./conduit
./start.sh       # runs ./conduit in the foreground
```

Required environment: `DATABASE_URL`, `JWT_SECRET`, `HOST`, `PORT`. Optional, with the measured defaults:

| Variable | Default | Meaning |
|---|---|---|
| `HTTP_WORKERS` | 2 | epoll threads |
| `DB_READERS` | 5 | read threads, one Postgres connection each |
| `DB_WRITERS` | 2 | write threads, one Postgres connection each |
| `BCRYPT_THREADS` | 2 | hashing threads |
| `BCRYPT_NICE` | 0 | nice value of the first hashing thread |
| `GATHER_MS` | 2 | how long a list or feed batch gathers before it runs |
| `READ_BATCH` | 512 | most jobs in one read batch |
| `HTTP_GZIP` | 2 | 0 never, 1 always, 2 adaptive |
| `SCHED_BATCH` | 1 | run threads under `SCHED_BATCH` |

## How it works

Reads queue by family. A free reader takes the oldest ready queue, up to 512 jobs, and runs them as one statement with
array parameters, so a request's cost falls as load rises. Nothing is kept between batches: every request reads
Postgres while it is being served.

**Reads**

- **Separate queues and statements** for article views, the global list, and tag/author/favorited lists, so cheap jobs
  do not wait on long batches or pay for unused plan branches.
- **Each distinct article is enriched once per batch**, and articles, authors, tags and favorite counts are fetched with
  `= ANY(sorted array)`, which walks one index across neighbouring keys instead of descending for every row.
- **Viewer flags are read once per job** the same way, not once per article. Each job's row holds its page as article
  indexes plus the articles it favorited and the authors it follows, and the renderer works out the flags, not Postgres.
- **Global, tag, author and favorited lists build each distinct page once**, and jobs asking for it join to the result.
- **Tag, author and favorited lists scan each distinct key once.** That scan gives both the capped count and every page
  anyone in the batch asked for.
- **Feed:** a viewer following an author with 1,000+ articles has a count of exactly 1000, and a page that cannot reach
  below that author's m-th newest article. When that cutoff is recent, one shared scan of recent articles replaces all
  of the viewer's per-author reads. Other viewers read each followed author once per batch, no further than the deepest page or lowest cutoff of that
  author's viewers.
- **Joins between CTEs are avoided where row estimates are unknown.** Article indexes are contiguous, so an author is
  looked up by array position. The planner's low estimates had otherwise produced quadratic nested loops.

**Writes** are group commits: up to 128 per transaction on each write connection, and each reply is released only after
the commit returns. If a group fails, its writes are retried one at a time.

**bcrypt** runs at cost 10 in 1 to 6 interleaved lanes, whose table lookups overlap in the out-of-order window. XOR
commutes, so two P-array words go in with one 64-bit load every two rounds, and alternating which half feeds F avoids
rotates. A second thread runs only for a full batch that has waited 300 ms. Jobs waiting 8 s get a 503 rather than being hashed for a client about to give up.

**gzip** is greedy LZ77 with a 4096-entry hash and one fixed-Huffman block: fast rather than tight (about 0.56 on list
JSON). Bodies of at least 2,560 bytes are compressed only while the box sends over 100 MB/s with TCP retransmits, and
are kept only if smaller. `/api/tags` is skipped because it saves little for its CPU.

**Spinlocks** sleep on a futex with a 1 ms timeout after a short spin, so a preempted holder can get the CPU.

## Measurements

These are not official numbers. Server and Postgres 18.6 (in Docker) ran on a 4-core/8-thread Xeon E3-1230 v3 from 2013 with
31 GB of RAM. Postgres used the box's formulas for that RAM, not for 16 GB. The load generator ran on a separate i7-2600K over
gigabit, with 24,000 users, a 15 s ramp and 300 s measured.

Think scale multiplies think times and session lengths, so 24,000 users at scale 0.16 offer the load of about 150,000 real users,
including their login rate. Latency does not carry over: a scale below 1 shrinks the wait a saturated server causes.

| Equivalent users (think scale) | Req/s | p95 | p99 | Login errors | Minute 2 to minute 5, req/s |
|---|---|---|---|---|---|
| 150,000 (0.16) | 34,249 | 200 ms | 300 ms | 0% | 34,913 to 33,393 |
| 200,000 (0.12), run 1 | 35,671 | 386 ms | 527 ms | 6.18% | 36,479 to 34,396 |
| 200,000 (0.12), run 2 | 35,565 | 390 ms | 550 ms | 3.91% | 36,588 to 33,622 |

The ceiling near 35,500 req/s is the limit that matters here. A real 150,000-user run on the official box needs about 38,800 req/s,
which this older machine does not reach, so these runs do not predict an official score.

Two problems remain. Throughput falls as a run goes on, partly because new articles push viewers' feed cutoffs out of the shared
window. All writes also stall together for a few seconds in some runs. The stalls overlap disk-busy periods, but their cause is
not established.

## Credits

Ideas came from other entries' READMEs and SQL: `asm-epoll-nickita-khylkouski` (`= ANY` enrichment, per-job flag arrays,
hub-based feed window and its small size limits, a helper hashing thread only for full batches, adaptive gzip rule, shedding old bcrypt jobs, `SCHED_BATCH`) and the top Rust and Zig entries
(batch deduplication, per-reactor FD tables, feed cutoffs). The code here is written separately.
