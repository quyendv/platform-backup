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
  : "${MONGODUMP_OPLOG:=auto}"
  case "$MONGODUMP_OPLOG" in
    auto | true | false) ;;
    *) die "MONGODUMP_OPLOG must be auto, true or false (got '${MONGODUMP_OPLOG}')" ;;
  esac
}

# _uri_names_database URI — true when the URI's path names a database.
# mongodump only takes an oplog on a full dump, and a database in the path
# narrows the dump to that database.
_uri_names_database() {
  local rest="${1#*://}"
  rest="${rest#*@}"
  [[ "$rest" == */* ]] || return 1
  rest="${rest#*/}"
  rest="${rest%%\?*}"
  [[ -n "$rest" ]]
}

# _want_oplog — whether this run dumps with --oplog. `auto` reads the URI, the
# one thing it can know without a client: a replicaSet option or an SRV record
# means a replica set, and an oplog makes the dump a single point in time
# instead of a smear across however long it took.
_want_oplog() {
  case "${MONGODUMP_OPLOG:-auto}" in
    true) return 0 ;;
    false) return 1 ;;
  esac
  if _uri_names_database "$MONGODB_URI"; then
    log_info "No --oplog: the URI names a database, and an oplog needs a full dump"
    return 1
  fi
  [[ "$MONGODB_URI" == mongodb+srv://* || "$MONGODB_URI" =~ [?\&]replicaSet= ]]
}

backend_dump() {
  local dir="$1" name="mongodb-${RUN_ID}.archive.gz"
  local args=(--uri="$MONGODB_URI" --gzip)

  # The name carries the oplog, so restore knows to replay it without
  # opening the archive.
  if _want_oplog; then
    name="mongodb-${RUN_ID}.oplog.archive.gz"
    args+=(--oplog)
  fi

  log_info "mongodump: $(mongodump --version | head -n1)"
  # Checked explicitly; see the note in the postgresql adapter.
  mongodump "${args[@]}" --archive="${dir}/${name}" ||
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
  if [[ "$(basename -- "$file")" == *.oplog.archive.gz ]]; then
    log_info "The archive carries an oplog; replaying it"
    args+=(--oplogReplay)
  fi

  log_info "mongorestore: $(mongorestore --version | head -n1)"
  mongorestore "${args[@]}"
}
