# etcd

`ghcr.io/quyendv/platform-backup/etcd`

`etcdctl snapshot save`, with the snapshot verified by `etcdutl snapshot status`
before it is uploaded. The image carries etcdctl and etcdutl 3.7; both are
tested against etcd 3.5, 3.6 and 3.7 servers, from snapshot to a member started
on the restored data.

**This image backs up and fetches. It does not restore.** See below.

## Variables

| Variable | Required | Default | Notes |
|---|:--:|---|---|
| `ETCD_MODE` | | `kubeadm` | `kubeadm` / `kubespray` / `explicit` |
| `ETCD_ENV_FILE` | | `/etc/etcd.env` | Sourced when `ETCD_MODE=kubespray` |
| `ETCDCTL_ENDPOINTS` | | *(per mode)* | |
| `ETCDCTL_CACERT` | | *(per mode)* | |
| `ETCDCTL_CERT` | | *(per mode)* | |
| `ETCDCTL_KEY` | | *(per mode)* | |

Plus the [shared variables](../../README.md#environment).

`ETCD_MODE` only decides where the four `ETCDCTL_*` values come from:

- **kubeadm** — the standard `/etc/kubernetes/pki/etcd` paths and
  `https://127.0.0.1:2379`. Mount that directory read-only.
- **kubespray** — sourced from `ETCD_ENV_FILE` (etcd's own systemd environment
  file). Mount `/etc/etcd.env` read-only.
- **explicit** — you supply all four.

etcdctl 3.5+ rejects `ETCDCTL_*` environment variables when the equivalent
command-line flags are also present. The adapter reads the variables, unexports
them, and passes flags, so either style of configuration works.

## Backup

```bash
docker run --rm --network host \
  -e ETCD_MODE=kubeadm \
  -e AWS_ACCESS_KEY_ID=xxx -e AWS_SECRET_ACCESS_KEY=yyy \
  -e AWS_ENDPOINT_URL_S3=https://minio.example.com \
  -e S3_BUCKET=backups -e S3_PREFIX=backups/etcd \
  -v /etc/kubernetes/pki/etcd:/etc/kubernetes/pki/etcd:ro \
  ghcr.io/quyendv/platform-backup/etcd:latest
```

Host networking, because etcd listens on the host. Root, because
`server.key` is root-readable only.

## Restore

Restoring etcd is not a client operation. `etcdutl snapshot restore` writes a
new data directory for a **stopped** member, and every member of the cluster
has to be rebuilt from the same snapshot with its own name and peer URL. A
container talking to a running cluster cannot do that, so `MODE=restore` exits
with an error rather than pretending.

Fetch the snapshot with this image, then restore on each control-plane host:

```bash
# 1. Download and checksum-verify the snapshot
docker run --rm \
  -e MODE=fetch \
  -e AWS_ACCESS_KEY_ID=xxx -e AWS_SECRET_ACCESS_KEY=yyy \
  -e AWS_ENDPOINT_URL_S3=https://minio.example.com \
  -e S3_BUCKET=backups -e S3_PREFIX=backups/etcd \
  -v /var/tmp/etcd-restore:/restore \
  ghcr.io/quyendv/platform-backup/etcd:latest

# 2. On EACH control-plane node, with etcd stopped
etcdutl snapshot restore /var/tmp/etcd-restore/<run>/etcd-<run>.db \
  --name <this-member-name> \
  --initial-cluster <m1=https://ip1:2380,m2=https://ip2:2380,...> \
  --initial-advertise-peer-urls https://<this-ip>:2380 \
  --data-dir /var/lib/etcd
```

`etcdctl snapshot restore` was removed in etcd 3.6; use `etcdutl`. If the host
has none, the image's own works on a 3.5 cluster too: run it with
`--entrypoint etcdutl`, `/var/tmp/etcd-restore` and `/var/lib` mounted, and the
same arguments.

On kubeadm, stop etcd by moving `/etc/kubernetes/manifests/etcd.yaml` aside;
put it back once every member's data directory has been rebuilt. Set
`RESTORE_TIMESTAMP` on the fetch to pin a specific run.

## Docker

[`docker/compose.yaml`](docker/compose.yaml) runs the image on a schedule, with
a pinned release tag and a persistent `/backup` volume.

```bash
cd backends/etcd/docker
cp ../.env.example .env        # ETCD_MODE, the S3 settings, SCHEDULE
docker compose up -d
docker compose run --rm backup run   # one backup now, against the same volume
docker compose ps                    # (healthy) once a run has succeeded
docker compose logs -f backup
```

The service runs with host networking, because etcd listens on the host, and
mounts the kubeadm client certificates read-only. For kubespray, swap the
mounts for the commented ones and set `ETCD_MODE=kubespray`. Run it on one
control-plane node: a snapshot from one member is a snapshot of the cluster.

Restore and fetch:

```bash
docker compose run --rm restore        # download + verify into ./restore
# then follow "Restore" above on each control-plane node
```

The image never restores, as explained under [Restore](#restore).

With `SCHEDULE` set, `docker compose up -d` leaves the container running and
backing up on that cron; add `RESTART_POLICY=unless-stopped` to `.env` so it
comes back after a reboot. With `SCHEDULE` empty it takes one backup and exits,
like the image itself, and the restart policy has to stay at its default `no`:
otherwise every exit restarts it, and one backup becomes a loop.

The `/backup` volume is persistent, so `.last-run.json` survives restarts:
`docker ps` shows `(unhealthy)` once a run fails, and `NOTIFY_ON=change` works
here, unlike in Kubernetes. Set `HEALTHCHECK_MAX_AGE` as well to catch a
schedule that stopped firing. `restore` is a separate service so that a manual
fetch or restore never overwrites the scheduled job's state.

## Kubernetes

[`k8s/`](k8s/) has a CronJob pinned to a
control-plane node with the etcd PKI mounted, and a fetch Job — not a restore
Job, for the reason above.

Notifications are configured in the same Secret. Leave `NOTIFY_ON=failure`
there: each run is a fresh pod with an `emptyDir`, so the state file never
survives and "previous outcome" is always unknown — `change` would fire on
every run, and a recovery message can never be sent. Failures notify either
way, which is the part that matters. Mount a PersistentVolumeClaim at
`/backup` if you want both.
