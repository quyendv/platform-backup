#!/usr/bin/env bash
# PostgreSQL adapter: pg_dump in custom format, gzipped.
#
# The image tag must match the server major version — pg_dump refuses to dump a
# server newer than itself, which is why this backend is built as a matrix.
#
# Sourced by lib/main.sh, which has already loaded lib/log.sh and lib/env.sh.

backend_name() { printf 'postgresql'; }
backend_caps() { printf 'fetch restore'; }

# Connection flags shared by every client. --no-password is deliberately not
# here: pg_isready does not accept it, and PGPASSWORD covers authentication for
# the clients that do.
_conn_args() {
  printf '%s\n' -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER"
}

backend_validate() {
  require_env POSTGRES_HOST POSTGRES_PORT POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB
  export PGPASSWORD="$POSTGRES_PASSWORD"
  : "${POSTGRES_MAINTENANCE_DB:=postgres}"
}

backend_dump() {
  local dir="$1" name="postgresql-${RUN_ID}.dump.gz"
  local args=()
  mapfile -t args < <(_conn_args)

  pg_isready "${args[@]}" -q ||
    die "Cannot reach PostgreSQL at ${POSTGRES_HOST}:${POSTGRES_PORT}"
  log_info "pg_dump: $(pg_dump --version)"

  # pg_dump writes the archive to stdout; only the pipeline's exit status tells
  # us it worked, so pipefail (set in the entrypoint) is what makes this safe.
  # Checked explicitly rather than left to errexit: backend_dump ends by
  # echoing the filename, and errexit is disabled inside the tested context the
  # driver calls this from, so a failed pg_dump would otherwise be reported
  # three steps later as "artifact too small".
  pg_dump "${args[@]}" --no-password -d "$POSTGRES_DB" --format=custom |
    gzip >"${dir}/${name}" ||
    die "pg_dump failed for ${POSTGRES_DB} on ${POSTGRES_HOST}"

  printf '%s' "$name"
}

# pg_restore --list parses the archive's table of contents, so it fails on a
# truncated or corrupt dump while accepting a valid dump of an empty database.
backend_verify() {
  local file="$1"
  gzip -t "$file" || return 1
  gunzip -c "$file" | pg_restore --list >/dev/null
}

backend_restore() {
  local file="$1"
  local args=()
  mapfile -t args < <(_conn_args)
  args+=(--no-password)

  if bool_is_true RESTORE_DROP; then
    log_warn "RESTORE_DROP is set — dropping and recreating ${POSTGRES_DB}"
    psql "${args[@]}" -d "$POSTGRES_MAINTENANCE_DB" -v ON_ERROR_STOP=1 -q <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
 WHERE datname = '${POSTGRES_DB}' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS "${POSTGRES_DB}";
CREATE DATABASE "${POSTGRES_DB}";
SQL
  fi

  local restore_args=("${args[@]}" -d "$POSTGRES_DB")
  if bool_is_true RESTORE_CLEAN; then
    restore_args+=(--clean --if-exists)
  fi

  log_info "pg_restore: $(pg_restore --version)"
  gunzip -c "$file" | pg_restore "${restore_args[@]}"
}
