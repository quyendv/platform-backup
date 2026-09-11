#!/usr/bin/env bash
# HashiCorp Vault adapter: Raft integrated-storage snapshots.
#
# Backup needs only read on sys/storage/raft/snapshot (policies/backup-raft.hcl).
# Restore needs a far broader policy and overwrites the entire Vault state, so it
# is deliberately a separate, explicit operation.
#
# Sourced by lib/main.sh, which has already loaded lib/log.sh and lib/env.sh.

backend_name() { printf 'vault'; }
backend_caps() { printf 'fetch restore'; }

backend_validate() {
  require_env VAULT_ADDR
  if [[ -z "${VAULT_TOKEN:-}" ]]; then
    [[ -n "${VAULT_TOKEN_FILE:-}" && -f "$VAULT_TOKEN_FILE" ]] ||
      die "Set VAULT_TOKEN, or VAULT_TOKEN_FILE pointing at a readable file"
    VAULT_TOKEN="$(<"$VAULT_TOKEN_FILE")"
  fi
  export VAULT_ADDR VAULT_TOKEN
}

backend_dump() {
  local dir="$1" name="vault-${RUN_ID}.snap.gz"

  # Checked explicitly; see the note in the postgresql adapter.
  vault operator raft snapshot save "${dir}/vault-${RUN_ID}.snap" >&2 ||
    die "vault raft snapshot save failed against ${VAULT_ADDR}"
  gzip -9 "${dir}/vault-${RUN_ID}.snap" || die "compressing the snapshot failed"

  printf '%s' "$name"
}

# The snapshot is gzipped; gzip -t catches a truncated write.
backend_verify() {
  gzip -t "$1"
}

backend_restore() {
  local file="$1" snap="${1%.gz}"

  log_warn "Restoring a Vault snapshot replaces the entire Raft state"
  gunzip -kf "$file"
  vault operator raft snapshot restore -force "$snap" >&2
  rm -f "$snap"
}
