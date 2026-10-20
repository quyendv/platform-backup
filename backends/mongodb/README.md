# mongodb

`ghcr.io/quyendv/platform-backup/mongodb`

`mongodump --gzip --archive`, a single portable archive file. Restores with
`mongorestore`.

## Variables

| Variable | Required | Default | Notes |
|---|:--:|---|---|
| `MONGODB_URI` | ✅ | — | Carries host, credentials, replica set and TLS options |
| `RESTORE_DROP` | | `false` | Pass `--drop` to `mongorestore` |

Plus the [shared variables](../../README.md#environment).

URI forms:

```
mongodb://user:pass@host:27017/?authSource=admin
mongodb://user:pass@host:27017/mydb?replicaSet=rs0&authSource=admin
mongodb+srv://user:pass@cluster.mongodb.net/
```

## Restore

Without `RESTORE_DROP=true`, `mongorestore` merges into what is already there:
existing documents with the same `_id` are kept and the restored versions
skipped. That is rarely what you want after a data-loss incident, but it is the
safe default. Set `RESTORE_DROP=true` to drop each collection first.

## Architectures

The image is amd64 and arm64. MongoDB publishes its Debian packages for x86_64
only, so the arm64 build installs the official database-tools tarball instead —
same tools, pinned by `DBTOOLS_VERSION`.

## Docker

[`docker/compose.yaml`](docker/compose.yaml) runs the image on a schedule, with
a pinned release tag and a persistent `/backup` volume.

```bash
cd backends/mongodb/docker
cp ../.env.example .env        # MONGODB_URI, the S3 settings, SCHEDULE
docker compose up -d
docker compose run --rm backup run   # one backup now, against the same volume
docker compose ps                    # (healthy) once a run has succeeded
docker compose logs -f backup
```

**Reaching the server.** For a server on the same host with a published port,
use `host.docker.internal` as the host: the compose file maps it to the host.
For a server in another Compose project, uncomment `networks:` in the compose
file, set the name to that project's network (`docker network ls`) and use the
server's service name as the host.

Restore and fetch:

```bash
docker compose run --rm restore        # download + verify into ./restore
docker compose run --rm -e MODE=restore -e RESTORE_DROP=true restore
```

An empty `SCHEDULE` becomes `0 2 * * *` (daily, 02:00 UTC) in the `backup`
service: without one the container would back up once, exit, and be restarted
by its restart policy — a backup loop.

The `/backup` volume is persistent, so `.last-run.json` survives restarts:
`docker ps` shows `(unhealthy)` once a run fails, and `NOTIFY_ON=change` works
here, unlike in Kubernetes. Set `HEALTHCHECK_MAX_AGE` as well to catch a
schedule that stopped firing. `restore` is a separate service so that a manual
fetch or restore never overwrites the scheduled job's state.

## Kubernetes

[`k8s/`](k8s/). `MONGODB_URI` carries the credentials, which is why the whole
configuration lives in a Secret.

Notifications are configured in the same Secret. Leave `NOTIFY_ON=failure`
there: each run is a fresh pod with an `emptyDir`, so the state file never
survives and "previous outcome" is always unknown — `change` would fire on
every run, and a recovery message can never be sent. Failures notify either
way, which is the part that matters. Mount a PersistentVolumeClaim at
`/backup` if you want both.
