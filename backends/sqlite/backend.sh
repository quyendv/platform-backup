#!/usr/bin/env bash
# SQLite adapter: one database file, read from a mounted volume.
#
# Unlike every other backend the data is a file, not a server, so this image
# runs next to it. Three measured facts shape the adapter (see
# docs/superpowers/specs/2026-10-08-sqlite-backend-design.md):
#
#   - .backup restarts whenever the source is written and may never finish on a
#     busy database; VACUUM INTO copies one consistent snapshot.
#   - A leftover -wal is replayed over a restored file, silently; restore moves
#     it away with the database it belongs to.
#   - An open, idle connection cannot be seen from another process; restore
#     requires the application to be stopped and says so, instead of pretending
#     to check.
#
# Sourced by lib/main.sh, which has already loaded lib/log.sh and lib/env.sh.

backend_name() { printf 'sqlite'; }
backend_caps() { printf 'fetch restore'; }

: "${SQLITE_BUSY_TIMEOUT_MS:=10000}"
# Reads are tried again for a while: on a read-only mount, opening fails for a
# moment whenever an application that opens and closes its database per request
# removes and recreates the -shm.
: "${SQLITE_OPEN_RETRIES:=10}"
: "${SQLITE_OPEN_RETRY_SECONDS:=1}"

# _sqlite_source_uri -> the URI the database is read through, never for writing.
# Fails (status 1, a message on stderr) when the header cannot be read: the
# caller must not go on with an empty URI, which sqlite3 opens as a private,
# empty database.
#
# A WAL database (header byte 18 is 2) with no -shm and no WAL content is opened
# immutable=1: on a writable mount mode=ro would create a -wal/-shm pair owned by
# this image's user, which the application may then be unable to write. "No
# -shm" only means no connection is open right now, so _sqlite_read checks that
# the file did not change while it was read. A WAL left with content (an
# application that died) is read with mode=ro, which replays it: immutable would
# skip its commits.
_sqlite_source_uri() {
  local path="$SQLITE_PATH" mode
  if ! mode="$(od -An -tu1 -j18 -N1 -- "$path" 2>/dev/null)" || [[ -z "${mode// /}" ]]; then
    printf 'Cannot read the header of %s\n' "$path" >&2
    return 1
  fi
  mode="${mode// /}"
  # As root, SQLite gives the -wal/-shm it creates to the database's owner, so
  # a locked read is always possible and immutable is never needed.
  if [[ "$(id -u)" != 0 && "$mode" == "2" && ! -e "${path}-shm" && ! -s "${path}-wal" ]]; then
    printf 'file:%s?mode=ro&immutable=1' "$path"
  else
    printf 'file:%s?mode=ro' "$path"
  fi
}

# _sqlite_state -> what changes when anything writes into the database file
# itself (a checkpoint, a rollback-journal commit): its inode, size and mtime.
_sqlite_state() { stat -c '%i %s %.9Y' -- "$SQLITE_PATH" 2>/dev/null; }

# _sqlite_read [--clean FILE] SQL...: run statements through the read-only URI,
# tried again until a copy is made while nothing wrote the database file.
#
# This image cannot take part in the application's locking: on a read-only
# mount it cannot write the read marks in the -shm, and with no -shm there is
# nothing shared at all. A checkpoint can then overwrite pages under the copy,
# which shows as "database disk image is malformed", or not at all. So a copy is
# kept only when the file's inode, size and mtime did not move while it was
# read, and any error is tried again, up to SQLITE_OPEN_RETRIES attempts
# SQLITE_OPEN_RETRY_SECONDS apart (on a read-only mount opening also fails for a
# moment while the application recreates its -shm). integrity_check on the
# result is the last word. The URI is worked out again each time. --clean
# removes FILE before each attempt, since VACUUM INTO refuses to write over what
# an interrupted one left. Stdout is the statements'; the last error goes to
# stderr.
_sqlite_read() {
  local attempt err="" clean="" uri before
  if [[ "${1:-}" == "--clean" ]]; then
    clean="$2"
    shift 2
  fi
  for ((attempt = 1; attempt <= SQLITE_OPEN_RETRIES; attempt++)); do
    [[ -z "$clean" ]] || rm -f -- "$clean"
    if ! uri="$(_sqlite_source_uri 2>&1)"; then
      err="$uri"
    else
      before="$(_sqlite_state)"
      if err="$(sqlite3 "$uri" ".timeout ${SQLITE_BUSY_TIMEOUT_MS}" "$@" 2>&1 >&3)"; then
        [[ "$(_sqlite_state)" == "$before" ]] && return 0
        err="${SQLITE_PATH} changed during the copy"
      fi
    fi
    ((attempt < SQLITE_OPEN_RETRIES)) || break
    log_warn "attempt ${attempt}/${SQLITE_OPEN_RETRIES}: ${err}"
    sleep "$SQLITE_OPEN_RETRY_SECONDS"
  done 3>&1
  [[ -z "$clean" ]] || rm -f -- "$clean"
  printf '%s\n' "$err" >&2
  return 1
}

backend_validate() {
  case "${MODE:-backup}" in
    # fetch only reads the object store.
    fetch) return 0 ;;
    # The database may be damaged or gone: that is what a restore is for. Only
    # the directory it goes in has to be there.
    restore)
      require_env SQLITE_PATH
      [[ -d "$(dirname -- "$SQLITE_PATH")" ]] ||
        die "The directory of SQLITE_PATH ${SQLITE_PATH} is missing (is the volume mounted?)"
      return 0
      ;;
  esac
  require_env SQLITE_PATH
  require_int SQLITE_OPEN_RETRIES SQLITE_OPEN_RETRY_SECONDS SQLITE_BUSY_TIMEOUT_MS
  ((SQLITE_OPEN_RETRIES > 0)) || die "SQLITE_OPEN_RETRIES must be 1 or more"
  [[ -e "$SQLITE_PATH" ]] ||
    die "SQLITE_PATH ${SQLITE_PATH} does not exist (is the volume mounted, has the application created it yet?)"
  [[ -r "$SQLITE_PATH" ]] || die "SQLITE_PATH ${SQLITE_PATH} is not readable by uid $(id -u)"
  # SQLite opens a short or empty file as an empty database without complaint;
  # the header is what says this is one.
  if [[ "$(head -c 15 -- "$SQLITE_PATH")" != "SQLite format 3" ]] ||
    ! _sqlite_read 'PRAGMA schema_version' >/dev/null 2>&1; then
    die "${SQLITE_PATH} does not open as a SQLite database"
  fi
}

backend_dump() {
  local dir="$1" name="sqlite-${RUN_ID}.sqlite.gz"

  log_info "sqlite3: $(sqlite3 --version | cut -d' ' -f1)"
  # Checked explicitly: this function ends by echoing the filename, so its own
  # status would otherwise reflect that echo rather than the copy.
  _sqlite_read --clean "${dir}/dump.sqlite" "VACUUM INTO '${dir}/dump.sqlite'" >&2 ||
    die "VACUUM INTO failed for ${SQLITE_PATH}"

  gzip -c "${dir}/dump.sqlite" >"${dir}/${name}" || die "compressing the database failed"
  rm -f -- "${dir}/dump.sqlite"

  printf '%s' "$name"
}

# _sqlite_unpack ARCHIVE OUT: decompress, and prove the database is whole. A
# size floor cannot tell a small database from a truncated one.
_sqlite_unpack() {
  local archive="$1" out="$2" result
  gzip -t "$archive" || die "Artifact is not a valid gzip: ${archive}"
  gunzip -c "$archive" >"$out" || {
    rm -f -- "$out"
    die "Could not decompress ${archive}"
  }
  result="$(sqlite3 "$out" 'PRAGMA integrity_check' 2>&1)" || true
  if [[ "$result" != "ok" ]]; then
    rm -f -- "$out"
    die "integrity_check failed: ${result}"
  fi
}

backend_verify() {
  local tmp="${BACKUP_DIR:-/tmp}/.verify-$$.sqlite"
  _sqlite_unpack "$1" "$tmp"
  rm -f -- "$tmp"
  log_info "Database passes integrity_check"
}

backend_restore() {
  local archive="$1" path
  # Through a symlink, the file it points to is what gets replaced.
  path="$(readlink -f -- "$SQLITE_PATH")" || die "Cannot resolve ${SQLITE_PATH}"
  # Named by when the restore ran (UTC, like run ids): a backup run id belongs to
  # MODE=backup only.
  local stamp="${RUN_ID:-$(date -u +%Y%m%d_%H%M%S)}"
  local next="${path}.restore-${stamp}" old="${path}.pre-restore-${stamp}" side

  log_warn "Restore replaces ${path}: the application must be stopped (an open connection cannot be detected)"
  # Unpacked next to the database, so the final mv is a rename on one filesystem.
  _sqlite_unpack "$archive" "$next"

  if [[ -e "$path" ]]; then
    # The application usually runs under another uid: a file owned by this
    # image's user would be read-only to it. Changing the owner needs root.
    chmod --reference="$path" -- "$next" || die "Could not copy the mode of ${path}"
    chown --reference="$path" -- "$next" 2>/dev/null ||
      log_warn "Could not give the restored file the owner of ${path} (not root): fix the owner if the application cannot write it"
    mv -- "$path" "$old" || die "Could not move ${path} aside"
  else
    # Nothing to copy an owner from: the volume's group may write it (the
    # application usually reaches its files through that group).
    chmod 0664 -- "$next" || die "Could not set the mode of ${next}"
    log_warn "No previous database: ${path} is mode 0664 and owned by uid $(id -u); fix the owner if the application needs it"
  fi
  # A leftover WAL would be replayed over the restored file: it stays with the
  # database it belongs to. Nothing is deleted.
  for side in -wal -shm -journal; do
    if [[ -e "${path}${side}" ]]; then
      mv -- "${path}${side}" "${old}${side}" || die "Could not move ${path}${side} aside"
    fi
  done
  mv -- "$next" "$path" || die "Could not put the restored database in place"

  if [[ -e "$old" ]]; then
    log_ok "Restored ${path}; the previous one is kept as ${old}"
  else
    log_ok "Restored ${path}"
  fi
}
