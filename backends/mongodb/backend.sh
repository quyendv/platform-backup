#!/usr/bin/env bash
# MongoDB adapter: mongodump to a single gzipped archive.
#
# One connection URI carries host, credentials, replica set and TLS options, so
# this backend has no host/port/user variables of its own.
#
# Sourced by lib/main.sh, which has already loaded lib/log.sh and lib/env.sh.

backend_name() { printf 'mongodb'; }
backend_caps() { printf 'fetch restore'; }

backend_validate() {
  require_env MONGODB_URI
}

backend_dump() {
  local dir="$1" name="mongodb-${RUN_ID}.archive.gz"

  log_info "mongodump: $(mongodump --version | head -n1)"
  # Checked explicitly; see the note in the postgresql adapter.
  mongodump --uri="$MONGODB_URI" --gzip --archive="${dir}/${name}" ||
    die "mongodump failed"

  printf '%s' "$name"
}

# mongodump writes a gzip stream; a truncated upload or a dump that died
# halfway fails the integrity check.
backend_verify() {
  gzip -t "$1"
}

backend_restore() {
  local file="$1"
  local args=(--uri="$MONGODB_URI" --gzip --archive="$file")

  if bool_is_true RESTORE_DROP; then
    log_warn "RESTORE_DROP is set — collections will be dropped before restore"
    args+=(--drop)
  fi

  log_info "mongorestore: $(mongorestore --version | head -n1)"
  mongorestore "${args[@]}"
}
