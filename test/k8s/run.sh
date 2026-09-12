#!/usr/bin/env bash
# Proves the offline restore runbook in backends/redis/README.md on a real
# cluster: the Bitnami chart with replicas, corrupted data, restored, replicas
# resynced.
#
# It renders and applies the manifest the repository actually ships. Testing a
# copy would let the documented one rot without anyone noticing — which is the
# failure this whole exercise exists to prevent.
#
# Roughly ten minutes, and it pulls the Bitnami image. Not part of `mise run
# check`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER="${K8S_TEST_CLUSTER:-pb-k8s-test}"
CTX="kind-${CLUSTER}"
NS=default
REL=redis
PASSWORD=secret
KEEP="${K8S_TEST_KEEP:-false}"

# Matches the chart's own image, which is the point: the AOF has to be written
# by the build that will load it.
CHART_IMAGE="docker.io/bitnamilegacy/redis:latest"
BACKUP_IMAGE="ghcr.io/quyendv/platform-backup/redis:redis8"

pass() { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
info() { printf '\033[0;36m••••\033[0m %s\n' "$*"; }
fail() {
  printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2
  exit 1
}

kc() { kubectl --context "$CTX" -n "$NS" "$@"; }
redis_master() {
  kc exec "${REL}-master-0" -c redis -- \
    redis-cli -a "$PASSWORD" --no-auth-warning "$@" 2>/dev/null | tr -d '\r'
}

cleanup() {
  if [[ "$KEEP" == "true" ]]; then
    info "K8S_TEST_KEEP=true — leaving cluster ${CLUSTER} up"
    return
  fi
  info "Deleting cluster ${CLUSTER}"
  kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

start_cluster() {
  info "Creating cluster ${CLUSTER}"
  kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
  kind create cluster --name "$CLUSTER" >/dev/null
  kubectl --context "$CTX" wait --for=condition=Ready node --all --timeout=300s >/dev/null

  info "Loading ${BACKUP_IMAGE} into the cluster"
  docker image inspect "$BACKUP_IMAGE" >/dev/null 2>&1 ||
    fail "Build it first: mise run build"
  kind load docker-image "$BACKUP_IMAGE" --name "$CLUSTER" >/dev/null

  info "Installing the Bitnami Redis chart with two replicas"
  helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
  helm repo update >/dev/null
  helm --kube-context "$CTX" -n "$NS" install "$REL" bitnami/redis \
    --set architecture=replication \
    --set replica.replicaCount=2 \
    --set auth.password="$PASSWORD" \
    --set "image.repository=$(printf '%s' "${CHART_IMAGE#docker.io/}" | cut -d: -f1)" \
    --set global.security.allowInsecureImages=true \
    --set master.persistence.size=1Gi --set replica.persistence.size=1Gi \
    --wait --timeout 10m >/dev/null
}

seed_and_back_up() {
  info "Seeding"
  redis_master mset k1 v1 k2 v2 marker ORIGINAL >/dev/null
  redis_master rpush mylist a b c >/dev/null
  redis_master setex ttlkey 3600 temp >/dev/null
  [[ "$(redis_master dbsize)" == "5" ]] || fail "seed did not take"

  info "Backing up to a volume"
  kc apply -f - >/dev/null <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: backup-store}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
---
apiVersion: batch/v1
kind: Job
metadata: {name: redis-backup-now}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: backup
          image: ${BACKUP_IMAGE}
          imagePullPolicy: Never
          env:
            - {name: REDIS_URL, value: "redis://:${PASSWORD}@${REL}-master:6379/0"}
            - {name: S3_BUCKET, value: ""}
            - {name: NOTIFY_ON, value: "never"}
          volumeMounts: [{name: store, mountPath: /backup}]
      volumes:
        - {name: store, persistentVolumeClaim: {claimName: backup-store}}
YAML
  kc wait --for=condition=complete job/redis-backup-now --timeout=300s >/dev/null ||
    fail "backup job did not complete"
  pass "backup ran inside the cluster"
}

corrupt() {
  info "Corrupting the data, the way an incident would"
  redis_master set marker CORRUPTED >/dev/null
  redis_master set junk_key should_disappear >/dev/null
  redis_master del k1 >/dev/null
  [[ "$(redis_master get marker)" == "CORRUPTED" ]] || fail "corruption did not take"
}

restore_offline() {
  # Replicas first: with Sentinel one can be promoted the moment the master
  # goes, and would overwrite the restore with the data being discarded.
  info "Scaling replicas down, then the master"
  kc scale statefulset "${REL}-replicas" --replicas=0 >/dev/null
  kc scale statefulset "${REL}-master" --replicas=0 >/dev/null
  kc wait --for=delete "pod/${REL}-master-0" --timeout=300s >/dev/null

  info "Applying the shipped restore manifest"
  sed \
    -e "s|<your-namespace>|${NS}|g" \
    -e "s|<the PVC holding your backups>|backup-store|g" \
    -e "s|redis-data-<release>-master-0|redis-data-${REL}-master-0|g" \
    -e "s|image: docker.io/bitnamilegacy/redis:latest|image: ${CHART_IMAGE}|g" \
    "$ROOT/backends/redis/k8s/restore-offline-job.yaml" |
    sed -e "s|image: ghcr.io/quyendv/platform-backup/redis:redis8|image: ${BACKUP_IMAGE}\n          imagePullPolicy: Never|" |
    kc apply -f - >/dev/null

  kc wait --for=condition=complete job/redis-restore-offline --timeout=600s >/dev/null || {
    kc logs job/redis-restore-offline --all-containers >&2 || true
    fail "restore job did not complete"
  }
  pass "restore job wrote the volume"

  info "Bringing the master back"
  kc scale statefulset "${REL}-master" --replicas=1 >/dev/null
  kc wait --for=condition=ready "pod/${REL}-master-0" --timeout=600s >/dev/null || {
    kc logs "${REL}-master-0" -c redis --tail=20 >&2 || true
    fail "master did not become ready after the restore"
  }
}

verify() {
  local marker junk k1 ttl
  marker="$(redis_master get marker)"
  junk="$(redis_master exists junk_key)"
  k1="$(redis_master get k1)"
  ttl="$(redis_master ttl ttlkey)"

  [[ "$marker" == "ORIGINAL" ]] || fail "marker is '${marker}', expected ORIGINAL"
  [[ "$junk" == "0" ]] || fail "junk_key survived the restore"
  [[ "$k1" == "v1" ]] || fail "deleted key k1 was not restored"
  ((ttl > 0)) || fail "TTL was not preserved (got '${ttl}')"
  pass "data reverted to the backup, TTL preserved (${ttl}s left)"

  info "Bringing the replicas back"
  kc scale statefulset "${REL}-replicas" --replicas=2 >/dev/null
  kc rollout status "statefulset/${REL}-replicas" --timeout=600s >/dev/null

  local p link size
  for p in "${REL}-replicas-0" "${REL}-replicas-1"; do
    link="$(kc exec "$p" -c redis -- redis-cli -a "$PASSWORD" --no-auth-warning \
      info replication 2>/dev/null | tr -d '\r' | sed -n 's/^master_link_status://p')"
    size="$(kc exec "$p" -c redis -- redis-cli -a "$PASSWORD" --no-auth-warning \
      dbsize 2>/dev/null | tr -d '\r')"
    [[ "$link" == "up" ]] || fail "${p} link is '${link}'"
    [[ "$size" == "5" ]] || fail "${p} has ${size} keys, expected 5"
  done
  pass "both replicas resynced from the restored master"
}

main() {
  local t
  for t in kind kubectl helm docker; do
    command -v "$t" >/dev/null || fail "$t not found; run mise install"
  done

  start_cluster
  seed_and_back_up
  corrupt
  restore_offline
  verify
  printf '\n\033[0;32mThe documented offline restore works on a real cluster\033[0m\n'
}

main "$@"
