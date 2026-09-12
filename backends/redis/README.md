# redis

`ghcr.io/quyendv/platform-backup/redis`

`redis-cli --rdb` pulls an RDB snapshot over the network, gzipped. Restore
stages that RDB on a throwaway `redis-server` inside the container and
`MIGRATE`s the keys across, which preserves data types and TTLs.

**Single-instance Redis only.** A Redis Cluster is refused — see below.

## Choosing a tag

Tags follow the **server's** major version: `redis7`, `redis8`, and `latest` =
`redis8`.

RDB is not backward compatible. Redis 8 writes `REDIS0015` and `redis-server`
7.4 refuses to start on it, so an image older than your server cannot verify or
restore its backups. Backup itself is unaffected — `--rdb` only receives bytes
— which makes this failure appear at restore time if the tag is wrong. Match
the tag to the server, or use a newer one.

## Variables

| Variable | Required | Default | Notes |
|---|:--:|---|---|
| `REDIS_URL` | ✅ | — | `redis://[[user]:password@]host[:port][/db]`; `rediss://` for TLS |
| `RESTORE_FLUSH` | | `false` | `FLUSHDB` the target before restoring |
| `REDIS_MIGRATE_BATCH` | | `100` | Keys per `MIGRATE` call |
| `REDIS_MIGRATE_TIMEOUT_MS` | | `30000` | Per-batch timeout |

Plus the [shared variables](../../README.md#environment).

## Restore

```bash
docker run --rm \
  -e MODE=restore -e RESTORE_FLUSH=true \
  -e REDIS_URL='redis://:password@cache.internal:6379/0' \
  -e AWS_ACCESS_KEY_ID=xxx -e AWS_SECRET_ACCESS_KEY=yyy \
  -e AWS_ENDPOINT_URL_S3=https://minio.example.com \
  -e S3_BUCKET=backups -e S3_PREFIX=backups/redis \
  ghcr.io/quyendv/platform-backup/redis:redis8
```

Without `RESTORE_FLUSH`, keys are written with `REPLACE` and anything not in
the backup is left where it is. That is the safe default, but it means a
restore does not return the database to exactly its backed-up state.

Three things to know before relying on it:

- **Restore holds the whole dataset in this container's memory.** The staging
  server loads the entire RDB. Restoring a 10 GB Redis needs a 10 GB limit on
  the backup pod, or it is OOMKilled part way through.
- **Restore is O(keys).** Millions of keys will take a while; `MIGRATE` moves
  them in batches of `REDIS_MIGRATE_BATCH`.
- **A `rediss://` target cannot be restored into.** `MIGRATE` runs on the
  staging server and has no TLS option. The adapter refuses rather than
  restoring part of the keyspace; use `MODE=fetch` and load the RDB into the
  server directly instead. Backup over TLS works normally.

## Redis Cluster

Refused, deliberately. A cluster shards its keyspace across masters and
`redis-cli --rdb` returns only the node it is aimed at — `-c` does not change
that, because `--rdb` is that node's replication stream rather than an ordinary
command. Measured on a three-master cluster holding 100 keys:

```
rc1: 33 keys    rc2: 30 keys    rc3: 37 keys
```

Backing up through one URL would capture a third of the data and report
success. Until cluster support exists, run one backup per master with its own
`S3_PREFIX`:

```bash
redis-cli -h any-node CLUSTER NODES | awk '/master/ {print $2}'
```

This is the one place where the usual intuition — "point it at a replica URL,
like MongoDB" — does not hold. Every other backend here replicates a full copy
to every node, so any endpoint has all the data.

## Kubernetes

[`k8s/`](k8s/) has a CronJob and a one-shot restore Job that reuses its Secret.
Give the restore Job a memory limit at least the size of the dataset.

Notifications are configured in the same Secret. Leave `NOTIFY_ON=failure`
there: each run is a fresh pod with an `emptyDir`, so the state file never
survives and "previous outcome" is always unknown — `change` would fire on
every run, and a recovery message can never be sent. Failures notify either
way, which is the part that matters. Mount a PersistentVolumeClaim at
`/backup` if you want both.
