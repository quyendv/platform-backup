# redis backend — design

Date: 2026-09-12
Status: approved for implementation
Scope: single-instance Redis. Cluster is deferred, and refused explicitly.

## Why this needs a record

Two facts below were measured, not assumed, and both change the design. Anyone
revisiting "just add cluster support" or "one image is enough" should read them
first.

## Measurements

Run against real Redis containers on 2026-09-12.

**Redis Cluster shards; a single endpoint sees a fraction of the data.**
Three masters, 100 keys written through `redis-cli -c`:

```
rc1: 33 keys    rc2: 30 keys    rc3: 37 keys
```

`redis-cli --rdb` against rc1 returns 33 keys. **`redis-cli -c --rdb` also
returns 33** — cluster mode follows MOVED for ordinary commands, but `--rdb` is
that one node's replication stream. Backing up "the cluster" through one URL
silently captures a third of it.

This is why the usual intuition — "point it at a replica URL like MongoDB" —
does not carry over. Every backend supported so far replicates a *full copy* to
every node (PostgreSQL streaming replication, MongoDB replica sets, etcd raft,
Vault raft, Redis Sentinel). Redis Cluster is the first sharded topology in
this repository.

**RDB format is not backward compatible.** Redis 8.10.1 writes `REDIS0015`;
`redis-server` 7.4 refuses to start on it. Backup is unaffected — `--rdb` only
receives bytes — but verification and restore both load the file, so the
image's Redis must be at least the server's version. Hence a build matrix, as
with PostgreSQL.

**Restore over the network has no direct mechanism.** Redis has no command that
loads an RDB into a running server; the documented route is to place
`dump.rdb` in the data directory and restart, which needs filesystem access and
restart rights — the same bind etcd is in.

A path that stays inside the container was found and verified end to end: run a
throwaway `redis-server` on the fetched RDB, then `MIGRATE` its keys to the
target.

```
staged: 6 keys, ttlkey TTL=3580
target: dbsize=6, k2=v2, mylist=[a b c], myhash.f2=v2, ttlkey TTL=3580
```

Data types and TTLs survive. `MIGRATE ... AUTH <password> ... REPLACE KEYS ...`
was verified against a password-protected target.

## Design

Standard adapter; no change to `lib/`.

| Hook | Behaviour |
|---|---|
| `backend_validate` | require `REDIS_URL`, `PING`, and **refuse when `cluster_enabled:1`** |
| `backend_dump` | `redis-cli --rdb`, gzipped to `redis-<ts>.rdb.gz` |
| `backend_verify` | `gzip -t`, then load into a staging `redis-server` and `PING` — proof the RDB parses, which a size floor cannot give |
| `backend_restore` | decompress, stage, optionally `FLUSHDB`, then `MIGRATE` in batches |
| `backend_caps` | `fetch restore` |

**Environment.** `REDIS_URL` (`redis://[:password@]host:port[/db]`,
`rediss://` for TLS), matching the single-URI shape MongoDB already uses.
`RESTORE_FLUSH` (default `false`) empties the target first, parallel to
`RESTORE_DROP` elsewhere.

**Image.** `FROM redis:<major>-alpine`, which already ships both `redis-cli`
and the `redis-server` restore needs. Matrix over majors 7 and 8; tags
`redis7`, `redis8`, and `latest` = `redis8`. Numeric-only tags are avoided so
nothing collides with the semver release tags.

## Limitations, to be documented with the backend

- **Restore holds the whole dataset in the backup container's memory.** A 10 GB
  Redis needs a 10 GB limit on the backup pod, or it is OOMKilled part way
  through a restore.
- **Restore is O(keys).** Millions of keys will be slow.
- **A `rediss://` target may not be restorable.** `MIGRATE` has no TLS option.
  Unverified at design time; if it cannot work, the adapter refuses rather than
  restoring partially.

Backup is subject to none of these: `--rdb` goes through `redis-cli`, so TLS,
auth and large datasets are ordinary.

## Deferred: cluster support

Refused rather than approximated, so nobody backs up a third of their data
believing otherwise. When it is built it needs, at minimum:

- enumerate masters from `CLUSTER NODES` and dump each one;
- pack the per-master RDBs into a single artifact, because a run is one
  artifact plus one checksum and `_fetch_into` identifies the artifact *by*
  that checksum;
- restore through `redis-cli -c` rather than `MIGRATE`, since MIGRATE to a node
  that does not own the key's slot fails with MOVED.

## Testing

- **Unit** — cluster refusal; dump failure surfaced (the adapter must check its
  own tool, per the invariant in CLAUDE.md); URL parsing.
- **Integration** — real Redis seeded with several types and a TTL: backup,
  destroy, restore, verify the values and the remaining TTL.
