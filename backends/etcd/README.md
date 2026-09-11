# etcd

`ghcr.io/quyendv/platform-backup/etcd`

`etcdctl snapshot save`, with the snapshot verified by `etcdctl snapshot status`
before it is uploaded.

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

Restoring etcd is not a client operation. `etcdctl snapshot restore` writes a
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
etcdctl snapshot restore /var/tmp/etcd-restore/<run>/etcd-<run>.db \
  --name <this-member-name> \
  --initial-cluster <m1=https://ip1:2380,m2=https://ip2:2380,...> \
  --initial-advertise-peer-urls https://<this-ip>:2380 \
  --data-dir /var/lib/etcd
```

On kubeadm, stop etcd by moving `/etc/kubernetes/manifests/etcd.yaml` aside;
put it back once every member's data directory has been rebuilt. Set
`RESTORE_TIMESTAMP` on the fetch to pin a specific run.

## Kubernetes

[`k8s/`](k8s/) has a CronJob pinned to a
control-plane node with the etcd PKI mounted, and a fetch Job — not a restore
Job, for the reason above.
