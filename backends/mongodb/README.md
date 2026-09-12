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

## Kubernetes

[`k8s/`](k8s/). `MONGODB_URI` carries the credentials, which is why the whole
configuration lives in a Secret.

Notifications are configured in the same Secret. Leave `NOTIFY_ON=failure`
there: each run is a fresh pod with an `emptyDir`, so the state file never
survives and "previous outcome" is always unknown — `change` would fire on
every run, and a recovery message can never be sent. Failures notify either
way, which is the part that matters. Mount a PersistentVolumeClaim at
`/backup` if you want both.
