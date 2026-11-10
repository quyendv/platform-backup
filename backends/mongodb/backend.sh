#!/usr/bin/env bash
# MongoDB adapter: mongodump to a single gzipped archive.
#
# One connection URI carries host, credentials, replica set and TLS options, so
# this backend has no host/port/user variables of its own.
#
# Sourced by lib/main.sh, which has already loaded lib/log.sh and lib/env.sh.

backend_name() { printf 'mongodb'; }
backend_caps() { printf 'fetch restore migrate'; }

backend_validate() {
  require_env MONGODB_URI
  : "${MONGODUMP_OPLOG:=auto}"
  case "$MONGODUMP_OPLOG" in
    auto | true | false) ;;
    *) die "MONGODUMP_OPLOG must be auto, true or false (got '${MONGODUMP_OPLOG}')" ;;
  esac
  if [[ "${MODE:-backup}" == migrate ]]; then
    require_env DEST_MONGODB_URI
    bool_is_true MIGRATE_DROP || true
    if bool_is_true MIGRATE_DROP; then
      die "MIGRATE_DROP is unsupported: a destination hidden by a hostname alias could be the source, and --drop would destroy it"
    fi
  fi
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
  local output rc=0 matched=false
  output="$(mktemp)"
  mongorestore "${args[@]}" 2>&1 | tee "$output" >&2 || rc=$?
  if grep -q "restoring \`[^\`]*\` from" "$output"; then matched=true; fi
  rm -f -- "$output"
  ((rc == 0)) || die "mongorestore failed (exit ${rc})"

  # It exits 0 having matched nothing when the URI names a database the archive does not hold.
  if [[ "$matched" == false ]] && _uri_names_database "$MONGODB_URI"; then
    die "mongorestore restored nothing: the archive has no data for the database named in MONGODB_URI. It must match the backed-up database; see the README to restore under another name"
  fi
}

# URI components stay private; only the credential-free host list may be logged.
_migrate_uri_parts() {
  local rest="${1#*://}" authority path=''
  authority="${rest%%/*}"
  authority="${authority%%\?*}"
  _MONGO_HOSTS="${authority##*@}"
  if [[ "$rest" == */* ]]; then path="${rest#*/}"; fi
  _MONGO_DB="${path%%\?*}"
}

_migrate_host_key() {
  printf '%s' "$1" | tr '[:upper:],' '[:lower:]\n' | LC_ALL=C sort | paste -sd, -
}

# Client diagnostics can include connection strings, including on failure.
_migrate_redact() {
  sed -E 's@[[:alpha:]][[:alnum:]+.-]*://[^[:space:]"<>]+@[redacted URI]@g'
}

_migrate_mongo_nonempty() {
  awk -v selected="${2:-}" '/writing / {
    ns=$0; sub(/^.*writing [`]?/, "", ns); sub(/[` ].*$/, "", ns)
    split(ns, parts, ".")
    if (selected != "" || (parts[1] != "admin" && parts[1] != "config" && parts[1] != "local")) found=1
  } END { exit !found }' "$1"
}

# Parse the tools' measured document counts, accepting their optional namespace quotes.
_migrate_mongo_verify() {
  awk -v source="$3" -v target="$4" '
    function parse(line, prefix,    pos, tail) {
      sub("^.*" prefix " [`]?", "", line)
      pos=match(line, / \([0-9]+ document/)
      if (!pos) return 0
      ns=substr(line, 1, pos-1); sub(/`$/, "", ns)
      tail=substr(line, pos+2); count=tail+0
      failures=0
      if (prefix == "finished restoring" && tail !~ /, [0-9]+ failure/) return 0
      if (tail ~ /, [0-9]+ failure/) { sub(/^.*, /, "", tail); failures=tail+0 }
      return 1
    }
    FILENAME == ARGV[1] && /done dumping / {
      if (!parse($0, "done dumping")) next
      seen++
      split(ns, parts, ".")
      if (parts[1] == "admin" || parts[1] == "config" || parts[1] == "local") next
      if (ns ~ /^[^.]+\.system\.buckets\./) next
      if (source != "" && target != "" && source != target) ns=target substr(ns, length(source)+1)
      expected[ns]=count
    }
    FILENAME == ARGV[2] && /finished restoring / {
      if (!parse($0, "finished restoring")) next
      actual[ns]=count; failed[ns]=failures
    }
    END {
      if (!seen) { print "The source database does not exist or holds nothing"; exit 1 }
      for (name in expected) {
        if (!(name in actual) || expected[name] != actual[name] || failed[name] != 0) {
          if (bad++ < 20) print "Namespace count or failures differ: " name
        }
      }
      if (bad) exit 1
    }' "$1" "$2"
}

backend_migrate() (
  local source_db source_hosts dest_db dest_hosts target stripped options work codes=()
  _migrate_uri_parts "$MONGODB_URI"
  source_db="$_MONGO_DB" source_hosts="$_MONGO_HOSTS"
  _migrate_uri_parts "$DEST_MONGODB_URI"
  dest_db="$_MONGO_DB" dest_hosts="$_MONGO_HOSTS"
  if [[ -z "$source_db" && -n "$dest_db" ]]; then
    die "A full copy cannot target a single destination database"
  fi
  target="${dest_db:-$source_db}"
  local source_key dest_key
  source_key="$(_migrate_host_key "$source_hosts")" || die "Source host normalization failed"
  dest_key="$(_migrate_host_key "$dest_hosts")" || die "Destination host normalization failed"
  if [[ "$source_key" == "$dest_key" && "$source_db" == "$target" ]]; then
    die "Migration refused: source and destination name the same hosts and database"
  fi
  stripped="${DEST_MONGODB_URI%%\?*}"
  stripped="${stripped#*://}"
  stripped="${DEST_MONGODB_URI%%://*}://${stripped%%/*}/"
  options=''
  if [[ "$DEST_MONGODB_URI" == *\?* ]]; then options="${DEST_MONGODB_URI#*\?}"; fi
  # Only with credentials: without a user there is nothing to authenticate.
  if [[ -n "$dest_db" && "$stripped" == *@* && ! "&${options,,}" =~ \&authsource= ]]; then
    options="${options:+${options}&}authSource=${dest_db}"
  fi
  stripped+="${options:+?${options}}"

  work="$(mktemp -d)" || die "Cannot create migration log directory"
  trap 'rm -rf -- "$work"' EXIT
  local listing=(--uri="$stripped") dump=(--uri="$MONGODB_URI" --archive) restore=(--uri="$stripped" --archive)
  if [[ -n "$target" ]]; then listing+=(--db="$target"); fi
  if ! mongodump "${listing[@]}" --archive=/dev/null 2>"$work/list"; then
    _migrate_redact <"$work/list" >&2
    die "mongodump failed listing the destination; the destination account needs read access as well as restore"
  fi
  local inspection_status=0
  _migrate_mongo_nonempty "$work/list" "$target" || inspection_status=$?
  case "$inspection_status" in
    0) die "Destination is non-empty; drop the partial destination by hand before retrying" ;;
    1) ;;
    *) die "MongoDB destination namespace inspection failed" ;;
  esac
  if _want_oplog; then
    dump+=(--oplog)
    restore+=(--oplogReplay)
  fi
  if [[ -n "$source_db" && "$source_db" != "$target" ]]; then
    restore+=(--nsFrom="${source_db}.*" --nsTo="${target}.*")
  fi
  if mongodump "${dump[@]}" 2>"$work/dump" |
    mongorestore "${restore[@]}" 2>&1 | _migrate_redact | tee "$work/restore" >&2; then
    codes=("${PIPESTATUS[@]}")
  else
    codes=("${PIPESTATUS[@]}")
  fi
  _migrate_redact <"$work/dump" >&2
  if ((codes[0] != 0)); then log_error "mongodump failed streaming the source (exit ${codes[0]})"; fi
  if ((codes[1] != 0)); then log_error "mongorestore failed restoring the destination (exit ${codes[1]})"; fi
  ((codes[0] == 0 && codes[1] == 0)) || die "MongoDB migration stream failed"
  ((codes[2] == 0 && codes[3] == 0)) || die "Capturing mongorestore diagnostics failed"
  local mismatch
  mismatch="$(_migrate_mongo_verify "$work/dump" "$work/restore" "$source_db" "$target")" ||
    die "Migration verification failed: ${mismatch}"
)
