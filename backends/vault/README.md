# vault

`ghcr.io/quyendv/platform-backup/vault`

`vault operator raft snapshot save`, gzipped. Restores with
`vault operator raft snapshot restore`.

Raft integrated storage only. A Vault backed by Consul or another storage
backend is backed up by backing up that store instead.

## Variables

| Variable | Required | Default | Notes |
|---|:--:|---|---|
| `VAULT_ADDR` | ✅ | — | Must be reachable from inside the container |
| `VAULT_TOKEN` | one of the two | — | |
| `VAULT_TOKEN_FILE` | one of the two | — | File containing the token |

Plus the [shared variables](../../README.md#environment).

## Tokens and policy

Backups need one capability, not root:

```bash
vault policy write backup-raft policies/backup-raft.hcl
vault token create -policy=backup-raft -period=24h -orphan
```

[`policies/backup-raft.hcl`](policies/backup-raft.hcl)
grants `read` on `sys/storage/raft/snapshot`, plus `sys/health` and
`auth/token/renew-self`. It is a periodic token: renew it before the period
expires, or rotate the secret.

**Restore needs a much broader policy.** `sys/storage/raft/snapshot-force`
replaces the entire Vault state — every secret, mount and policy. Do not reuse
the backup token for it, and do not leave a restore-capable token mounted in a
scheduled job.

## Restore

```bash
docker run --rm \
  -e MODE=restore \
  -e VAULT_ADDR=https://vault.internal:8200 -e VAULT_TOKEN=<privileged token> \
  -e AWS_ACCESS_KEY_ID=xxx -e AWS_SECRET_ACCESS_KEY=yyy \
  -e AWS_ENDPOINT_URL_S3=https://minio.example.com \
  -e S3_BUCKET=backups -e S3_PREFIX=backups/vault \
  ghcr.io/quyendv/platform-backup/vault:latest
```

The restore is applied with `-force`, which is what allows a snapshot to be
loaded into a Vault whose cluster identity differs from the one it was taken
from. Vault seals itself afterwards; unseal it with the keys **belonging to the
snapshot**, not the ones for the cluster you just overwrote.

Use `MODE=fetch` first if you want the snapshot on disk and verified before
committing to any of this.

## Kubernetes

[`k8s/`](k8s/). The image runs as uid 100,
the base image's unprivileged `vault` user, so it satisfies `runAsNonRoot`.

Notifications are configured in the same Secret. Leave `NOTIFY_ON=failure`
there: each run is a fresh pod with an `emptyDir`, so the state file never
survives and "previous outcome" is always unknown — `change` would fire on
every run, and a recovery message can never be sent. Failures notify either
way, which is the part that matters. Mount a PersistentVolumeClaim at
`/backup` if you want both.
