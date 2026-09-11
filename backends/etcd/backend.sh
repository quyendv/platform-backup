#!/usr/bin/env bash
# etcd adapter: etcdctl snapshot save.
#
# Fetch only. A real etcd restore rewrites the data directory of a stopped
# member, which cannot be done from inside this container against a running
# cluster — so MODE=restore is refused rather than half-implemented.
#
# Sourced by lib/main.sh, which has already loaded lib/log.sh and lib/env.sh.

backend_name() { printf 'etcd'; }
backend_caps() { printf 'fetch'; }

: "${ETCD_MODE:=kubeadm}"
: "${ETCD_ENV_FILE:=/etc/etcd.env}"

_etcd_from_kubeadm() {
  : "${ETCDCTL_ENDPOINTS:=https://127.0.0.1:2379}"
  : "${ETCDCTL_CACERT:=/etc/kubernetes/pki/etcd/ca.crt}"
  : "${ETCDCTL_CERT:=/etc/kubernetes/pki/etcd/server.crt}"
  : "${ETCDCTL_KEY:=/etc/kubernetes/pki/etcd/server.key}"
}

_etcd_from_kubespray() {
  [[ -f "$ETCD_ENV_FILE" ]] ||
    die "ETCD_MODE=kubespray but ${ETCD_ENV_FILE} does not exist"
  # Operator-supplied file; its contents cannot be known at lint time.
  # shellcheck disable=SC1090,SC1091
  source "$ETCD_ENV_FILE"
  : "${ETCDCTL_ENDPOINTS:=${ETCD_LISTEN_CLIENT_URLS%%,*}}"
  : "${ETCDCTL_CACERT:=${ETCD_TRUSTED_CA_FILE:-}}"
  : "${ETCDCTL_CERT:=${ETCD_CERT_FILE:-}}"
  : "${ETCDCTL_KEY:=${ETCD_KEY_FILE:-}}"
}

backend_validate() {
  case "$ETCD_MODE" in
    kubeadm) _etcd_from_kubeadm ;;
    kubespray) _etcd_from_kubespray ;;
    explicit) : ;;
    *) die "Invalid ETCD_MODE '${ETCD_MODE}' (expected kubeadm, kubespray or explicit)" ;;
  esac

  require_env ETCDCTL_ENDPOINTS ETCDCTL_CACERT ETCDCTL_CERT ETCDCTL_KEY
  # etcdctl 3.5+ rejects ETCDCTL_* environment variables when the equivalent
  # flags are also given, so the flags are built from them and the variables
  # are unexported before etcdctl runs.
  export ETCDCTL_API=3
}

_etcdctl() {
  local endpoints="$ETCDCTL_ENDPOINTS" cacert="$ETCDCTL_CACERT" \
    cert="$ETCDCTL_CERT" key="$ETCDCTL_KEY"
  env -u ETCDCTL_ENDPOINTS -u ETCDCTL_CACERT -u ETCDCTL_CERT -u ETCDCTL_KEY \
    etcdctl \
    --endpoints "$endpoints" \
    --cacert "$cacert" \
    --cert "$cert" \
    --key "$key" \
    "$@"
}

backend_dump() {
  local dir="$1" name="etcd-${RUN_ID}.db"

  log_info "etcdctl: $(etcdctl version | head -n1)"
  _etcdctl snapshot save "${dir}/${name}" >&2

  printf '%s' "$name"
}

# A snapshot etcdctl cannot read back is not a backup. This runs as the
# driver's verification step so every backend reports integrity the same way.
backend_verify() {
  _etcdctl snapshot status "$1" -w table >&2
}

backend_restore_hint() {
  cat <<'HINT'
etcd is restored on the member host, not from this container. On each control
plane node, with etcd stopped:

  MODE=fetch ...                       # download the snapshot with this image
  etcdctl snapshot restore <snapshot.db> \
    --name <member-name> \
    --initial-cluster <name1=peer1,...> \
    --initial-advertise-peer-urls <peer-url> \
    --data-dir /var/lib/etcd

Then start etcd again. See docs/backends/etcd.md.
HINT
}
