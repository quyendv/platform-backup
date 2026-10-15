# Redis on large datasets

**Date:** 2026-10-15 · **Status:** accepted · **Scope:** `backends/redis`, plus `FETCH_DECOMPRESS` in `lib/main.sh`

The Redis adapter was built and tested on datasets that load in well under a
second. On a multi-GB instance it fails every run, and when it does not fail it
holds a second copy of the dataset in the backup container's memory. This
records why, and what replaces it.

All numbers below are from a synthetic dataset — 1,000,000 JSON-like string
values, `used_memory` 663 MiB, a 174 MB RDB — in the `redis8` image under a
2-CPU limit. They are for proportions, not for sizing.

## Problems

| # | problem | where |
|---|---|---|
| P1 | `backend_verify` loads the RDB into a staging `redis-server`: every backup run needs RAM ≈ the server's dataset | `backend_verify` → `_redis_stage` |
| P2 | staging is given 40 × 0.25 s to answer `PONG`. A loading server answers `LOADING`, so any RDB that takes more than 10 s to load fails as "would not start" — in verify **and in restore** | `_redis_stage` |
| P3 | verify decompresses the artifact back to disk: scratch holds the RDB twice over a run | `_redis_stage` |
| P4 | `gzip -6`, single-threaded, is the slowest step after the transfer | `backend_dump` |
| P5 | a `die` inside `_redis_stage` leaves `${BACKUP_DIR}/.verify-<pid>` behind. Its name is not a run name, so prune never removes it; in `SCHEDULE` mode every failed run leaves a full decompressed RDB on the volume | `_redis_stage` |
| P6 | the staging server is daemonised and outlives a failed run. The next run's server cannot bind the port, `|| true` hides that, and `ping` reaches the **previous** run's server — verify can pass against the wrong RDB | `_redis_stage` |

P5 and P6 were found by reading the code; the tests below are what confirm them.

## Measured

| step | time | size / memory |
|---|---|---|
| `gzip -6` | 5.40 s | 57.1 MB |
| `zstd -3`, one thread | 0.76 s | 57.5 MB |
| `zstd -3`, `ZSTD_NBTHREADS=2` | 0.40 s | 57.5 MB |
| `ZSTD_CLEVEL=9` | — | 52.7 MB |
| `zstd -dc x.zst \| redis-check-rdb /dev/stdin` | 0.52 s | peak RSS ≈ 8 MB |
| staging load (today's verify) | ≈ 1 s | RSS ≈ the dataset |

RDB values are already LZF-compressed, so codecs land close together on ratio
and differ mostly in CPU.

### What `redis-check-rdb` does and does not accept

Tried against the real binary (8.10.2), not assumed:

- It reads a pipe or a FIFO (`/dev/stdin` works); it does not need to seek.
- Through a pipe it still rejects a truncated RDB and a single flipped byte,
  exit status 1.
- When it rejects a stream early, the writer gets `SIGPIPE` (141) — a pipeline
  under `pipefail` fails, which is what we want.

### Why the dump is not streamed

`redis-cli --rdb -` writes to stdout, which would let the dump go straight into
the compressor with no raw RDB on disk. It is not safe: with diskless
replication (the default) the server ends the transfer with a 40-byte EOF
marker, and `redis-cli` removes it with `ftruncate` — which does nothing on a
pipe. The stdout copy ends in 40 bytes of hex. With disk-based replication there
is no marker, so stripping 40 bytes blindly would truncate a good RDB.
`redis-check-rdb` accepts the trailing bytes, so the check would not catch it
either. The dump keeps going to a file.

## Design

### 1. Verify parses, it does not load

```
backend_dump:   redis-cli --rdb dump.rdb → zstd → rm dump.rdb
backend_verify: zstd -dc <artifact> | redis-check-rdb /dev/stdin
```

`redis-check-rdb` parses every key and checks the trailing CRC64 — truncation,
corruption, and an RDB version the image cannot read, which are the failures the
staging load caught — while holding one key at a time. Running it on the
**compressed artifact through a pipe** checks the exact bytes that are uploaded,
codec included, and writes nothing to disk. That removes P1 and P3 from the
backup path, and P5/P6 with them, since backup no longer starts a server.

No `REDIS_VERIFY` switch: a staging load catches nothing the parse does not,
and the server it would start is the cost being removed.

The adapter checks the pipeline's status itself (`backend_verify` runs in a
tested context where errexit is off) and logs the key count from the check.

### 2. zstd for new artifacts, gzip still read

- New artifacts are `redis-<id>.rdb.zst`, written by `zstd -3`.
- No `COMPRESS*` variables. zstd reads `ZSTD_CLEVEL` and `ZSTD_NBTHREADS` from
  the environment itself, the same way the AWS CLI reads `AWS_*`: documented,
  never translated. zstd's default is one thread, which is right for a
  CPU-limited pod; `-T0` would count the node's CPUs, not the container's quota.
- Reading chooses the decompressor by extension, everywhere: `backend_verify`,
  staging for restore, `FETCH_DECOMPRESS` in `lib/main.sh`, and the offline
  restore Job. A prefix holding `.gz` runs from 0.4.x and `.zst` runs from now
  on restores either.
- `zstd` is added to the Redis Dockerfile. `lib/` learns `.zst` too, but only
  the Redis image ever produces one.

Kept to Redis. Whether other backends get zstd is a separate decision.

### 3. Staging that restore can rely on

Restore still stages the RDB and `MIGRATE`s from it; that design and its memory
cost stay (the offline route is the answer for large instances). What changes
is how the staging server is run:

- **Foreground, as a tracked child**, not `--daemonize yes`. The adapter holds
  its PID, so "the process exited" (corrupt or too-new RDB) fails fast and
  "still loading" keeps waiting — two states the old loop could not tell apart.
- **On a Unix socket inside the staging directory, with `--port 0`.** No TCP
  port, so nothing else can answer in its place (P6 cannot recur), and
  `REDIS_STAGE_PORT` goes away. MIGRATE connects outward and is unaffected.
- **Ready means `PONG`, bounded by `REDIS_STAGE_TIMEOUT`** (default 3600 s),
  with `loading_loaded_perc` logged every 10 s so a long load is visibly alive.
- **Every failure path stops the server and removes the directory** before
  dying. Explicitly, not from a trap — the same reason `lib/main.sh` gives for
  `_discard_staging`.

## Not doing

- Streaming the dump (above).
- A staging-load verify mode.
- zstd for other backends.
- Restore that avoids holding the dataset (an RDB-to-RESTORE converter). The
  offline restore is already 85× faster and is the documented route.

## Tests that go red first

Unit (bats, stubs):

- staging fails fast when `redis-server` exits, without waiting out the timeout;
- staging keeps waiting through `LOADING` past the old 10 s budget;
- staging gives up at `REDIS_STAGE_TIMEOUT`, and leaves no process and no directory;
- staging runs on a socket, never a TCP port;
- verify fails when the decompressor fails, and when `redis-check-rdb` does;
- verify never starts `redis-server`;
- dump writes `.rdb.zst`, removes `dump.rdb`, and checks the compressor's status.

Integration (real binaries — stubs prove the call, not that it is valid):

- backup → restore round trip, as today, now through `.zst`;
- restore of an RDB whose load takes well over 10 s (`key-load-delay`, a hidden
  server config, applied through a wrapper — no seam in the adapter);
- verify rejects a truncated and a bit-flipped artifact, and the run is not promoted;
- a `.gz` artifact from 0.4.x still stages and restores;
- `FETCH_DECOMPRESS=true` produces an RDB from a `.zst` run;
- `mise run test:k8s` — the offline Job reads `.zst`.

## Operator notes (Redis README)

- Backup memory no longer scales with the dataset. Scratch peaks at RDB + its
  compressed copy, ≈ 1.35× the RDB; size the volume from the server's last RDB,
  not from `used_memory`.
- Each run is one fork on the server (`--rdb` makes it produce an RDB); the
  stall is the server's `latest_fork_usec`. Choose the schedule with that in mind.
- Restore still needs memory ≈ the dataset. For large instances use the offline
  restore.
