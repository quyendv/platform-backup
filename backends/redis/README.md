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

## Two ways to restore

`MODE=restore` writes into a **running** server. It needs no volume access and
no restart rights, which makes it the right choice for moving data into a new
instance. It is also slow, and holds a second copy of the dataset in the
restore container's memory.

The alternative is to put the RDB on the server's own volume and start it.
Measured on 200,000 keys (a 9.2 MB RDB):

| | Time | Memory |
|---|---|---|
| `MODE=restore` (staging + MIGRATE) | **11 s** | dataset twice: staging + target |
| Offline (place the file, start) | **130 ms** | dataset once, in Redis |

Roughly 85× on this dataset, and the gap grows with key count — `MIGRATE` is
O(keys) while loading an RDB is bounded by disk.

**Both assume no traffic.** Neither restore is atomic: writes arriving during
one interleave with the data being restored, and afterwards there is no way to
tell which is which. Quiesce the clients first — that is a requirement, not a
recommendation.

### Offline restore: Docker

```bash
# 1. Fetch the artifact, uncompressed and checksum-verified
docker run --rm \
  -e MODE=fetch -e FETCH_DECOMPRESS=true \
  -e REDIS_URL='redis://:password@cache:6379/0' \
  -e AWS_ACCESS_KEY_ID=xxx -e AWS_SECRET_ACCESS_KEY=yyy \
  -e AWS_ENDPOINT_URL_S3=https://minio.example.com \
  -e S3_BUCKET=backups -e S3_PREFIX=backups/redis \
  -v "$PWD/restore:/restore" \
  ghcr.io/quyendv/platform-backup/redis:redis8

# 2. Stop Redis
docker compose stop redis

# 3. Replace the data. Both files matter — see the AOF note below.
docker run --rm -v redis_data:/data -v "$PWD/restore:/restore:ro" \
  redis:8-alpine sh -c '
    rm -rf /data/dump.rdb /data/appendonlydir
    cp /restore/*/redis-*.rdb /data/dump.rdb'

# 4. Start it again
docker compose start redis
```

If your Redis runs with `appendonly yes`, step 3 is not enough on its own —
read the next section before using it.

### The AOF trap

With `appendonly yes`, **Redis loads the AOF and ignores `dump.rdb` entirely**.
Placing the RDB appears to work and changes nothing. Deleting the AOF does not
help either: with AOF enabled and none present, Redis starts **empty** rather
than falling back to the RDB.

Both were measured, not assumed. There are two ways out:

**Start once with AOF off**, which makes Redis load the RDB, then turn it back
on so it rewrites the AOF from what it just loaded:

```bash
redis-server --appendonly no --dir /data   # loads dump.rdb
redis-cli CONFIG SET appendonly yes        # rebuilds the AOF from memory
```

**Or build the AOF before starting**, which is what the Kubernetes Job below
does, because changing a chart's configuration for one boot means two rollouts.

Either way: the AOF must be written by **the same Redis build that will load
it**. This image ships 8.10.1; a cluster running 8.0.3 rejected its AOF with
`Can't handle RDB format version 15` and crash-looped. Stage with the server's
own image, not with this one.

### Offline restore: Kubernetes, Bitnami chart with replicas

[`k8s/restore-offline-job.yaml`](k8s/restore-offline-job.yaml) is the Job; the
sequence around it matters as much as the Job itself.

**Scale the replicas down first.** They hold the state you are replacing, and
with Sentinel one of them can be promoted the moment the master disappears —
which would overwrite the restore with the data you are trying to discard.

```bash
NS=your-namespace
REL=redis

# 0. Stop the clients. Nothing below is atomic.

# 1. Replicas first, then the master
kubectl -n $NS scale statefulset $REL-replicas --replicas=0
kubectl -n $NS scale statefulset $REL-master   --replicas=0
kubectl -n $NS wait --for=delete pod/$REL-master-0 --timeout=5m

# 2. Write the restored state onto the master's volume
kubectl -n $NS apply -f k8s/restore-offline-job.yaml
kubectl -n $NS wait --for=condition=complete job/redis-restore-offline --timeout=10m

# 3. Master back, and check before letting replicas copy from it
kubectl -n $NS scale statefulset $REL-master --replicas=1
kubectl -n $NS wait --for=condition=ready pod/$REL-master-0 --timeout=5m
kubectl -n $NS exec $REL-master-0 -c redis -- \
  redis-cli -a "$PASSWORD" --no-auth-warning dbsize

# 4. Replicas resync from the restored master
kubectl -n $NS scale statefulset $REL-replicas --replicas=2
kubectl -n $NS rollout status statefulset/$REL-replicas --timeout=10m
```

Step 3 before step 4 is deliberate: if the master came up wrong, replicas that
have not started yet still hold nothing, and you can retry step 2 without
having propagated the mistake.

This sequence was run end to end against the Bitnami chart (`architecture=replication`,
two replicas) on a kind cluster: corrupted data, restored, and both replicas
came back reporting `master_link_status:up` with the restored contents.

### RESTORE_FLUSH and managed Redis

The Bitnami chart disables the flush commands by default
(`rename-command FLUSHDB ""`), and managed Redis services usually do the same.
`RESTORE_FLUSH=true` therefore fails there with "unknown command"; the adapter
says so explicitly rather than leaving you with the raw error.

Without it, keys are written with `REPLACE`: everything in the backup
overwrites what is there, and only keys absent from the backup survive. The
offline path has no such problem — it replaces the data files wholesale.

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
