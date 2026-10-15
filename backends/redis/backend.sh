#!/usr/bin/env bash
# Redis adapter: RDB snapshots pulled over the network.
#
# Restore is the awkward half. Redis has no command that loads an RDB into a
# running server — the documented route is to drop dump.rdb into the data
# directory and restart, which needs filesystem access this container does not
# have. So restore runs a throwaway redis-server on the fetched RDB and MIGRATEs
# its keys across, which preserves types and TTLs.
#
# The consequence is that restore holds the whole dataset in this container's
# memory. See README.md.
#
# Sourced by lib/main.sh, which has already loaded lib/log.sh and lib/env.sh.

backend_name() { printf 'redis'; }
backend_caps() { printf 'fetch restore'; }

: "${RESTORE_FLUSH:=false}"
# Keys per MIGRATE call. Large enough to keep round trips down, small enough
# that one slow batch cannot hit the timeout.
: "${REDIS_MIGRATE_BATCH:=100}"
: "${REDIS_MIGRATE_TIMEOUT_MS:=30000}"

# _redis_url_part FIELD -> host | port | password | db
#
# MIGRATE takes the target apart into separate arguments, so the single URL has
# to be split. Everything up to the *last* @ is credentials: a password may
# itself contain an @, and the host cannot.
_redis_url_part() {
  local field="$1" url="${REDIS_URL:-}" rest creds hostport
  case "$url" in
    redis://* | rediss://*) rest="${url#*://}" ;;
    *) die "REDIS_URL must start with redis:// or rediss:// (got '${url}')" ;;
  esac

  if [[ "$rest" == *@* ]]; then
    creds="${rest%@*}"
    hostport="${rest##*@}"
  else
    creds=""
    hostport="$rest"
  fi

  local db="0"
  if [[ "$hostport" == */* ]]; then
    db="${hostport#*/}"
    hostport="${hostport%%/*}"
    [[ -n "$db" ]] || db="0"
  fi

  case "$field" in
    host) printf '%s' "${hostport%%:*}" ;;
    port)
      if [[ "$hostport" == *:* ]]; then printf '%s' "${hostport##*:}"; else printf '6379'; fi
      ;;
    # "user:pass" or ":pass"; either way the password follows the first colon.
    password) [[ "$creds" == *:* ]] && printf '%s' "${creds#*:}" || printf '' ;;
    db) printf '%s' "$db" ;;
    *) die "Unknown URL field '${field}'" ;;
  esac
}

_redis_url_is_tls() { [[ "${REDIS_URL:-}" == rediss://* ]]; }

_redis() { redis-cli -u "$REDIS_URL" --no-auth-warning "$@"; }

backend_validate() {
  require_env REDIS_URL
  bool_is_true RESTORE_FLUSH || true
  require_int REDIS_STAGE_TIMEOUT
  ((REDIS_STAGE_TIMEOUT > 0)) || die "REDIS_STAGE_TIMEOUT must be at least 1 second"

  _redis ping 2>/dev/null | grep -q PONG ||
    die "Cannot reach Redis at $(_redis_url_part host):$(_redis_url_part port)"

  # A cluster shards its keyspace, and --rdb returns only the node it is aimed
  # at — cluster mode does not change that. Backing one node up would quietly
  # capture a fraction of the data, so refuse instead.
  if _redis info cluster 2>/dev/null | grep -q 'cluster_enabled:1'; then
    die "$(
      cat <<'HINT'
This server is part of a Redis Cluster, which this image does not support.

A cluster shards its keyspace across masters, and `redis-cli --rdb` returns
only the node it is pointed at — `-c` does not change that. Backing up through
one URL would capture a fraction of the data and report success.

Back up each master separately for now, one S3_PREFIX per master. See
backends/redis/README.md.
HINT
    )"
  fi
}

backend_dump() {
  local dir="$1" name="redis-${RUN_ID}.rdb.gz"

  log_info "redis-cli: $(redis-cli --version)"
  # Checked explicitly: this function ends by echoing the filename, so its own
  # status would otherwise reflect that echo rather than the transfer.
  _redis --rdb "${dir}/dump.rdb" >&2 ||
    die "redis-cli --rdb failed against $(_redis_url_part host):$(_redis_url_part port)"

  gzip -c "${dir}/dump.rdb" >"${dir}/${name}" || die "compressing the RDB failed"
  rm -f -- "${dir}/dump.rdb"

  printf '%s' "$name"
}

# How long a staging server may spend loading its RDB. A multi-GB dataset takes
# minutes; a fixed 10 s used to fail every one of them as "corrupt".
: "${REDIS_STAGE_TIMEOUT:=3600}"
# Seconds between readiness checks. A seam for the unit tests, which would
# otherwise spend real time waiting on a stub; not a documented setting.
: "${_REDIS_STAGE_POLL:=0.25}"

_REDIS_STAGE_PID=""
_REDIS_STAGE_DIR=""

# _redis_decompress ARCHIVE — writes the RDB to stdout, codec chosen by extension.
_redis_decompress() {
  case "$1" in
    *.gz) gzip -dc -- "$1" ;;
    *)
      log_error "Unrecognised artifact type: $1"
      return 1
      ;;
  esac
}

_stage_cli() { redis-cli -s "${_REDIS_STAGE_DIR}/redis.sock" "$@"; }

# _redis_stage ARCHIVE DIR
# Decompresses the artifact and starts a throwaway server on it. A corrupt or
# too-new RDB makes redis-server exit, which is the check.
#
# The server is a tracked child, not daemonised. Holding its PID is what tells
# "exited" from "still loading", and what lets every failure path stop it: a
# daemonised server outlived failed runs, and the next run's ping reached it in
# place of its own. For the same reason it listens on a socket in DIR and on no
# TCP port at all — nothing else can answer there.
_redis_stage() {
  local archive="$1" dir="$2"
  _REDIS_STAGE_DIR="$dir"
  mkdir -p "$dir"
  _redis_decompress "$archive" >"${dir}/dump.rdb" ||
    _redis_stage_fail "Could not decompress ${archive}"

  # --save '' so the staging server never writes, and appendonly no so it does
  # not try to replay a journal that is not there.
  redis-server --dir "$dir" --dbfilename dump.rdb \
    --port 0 --unixsocket "${dir}/redis.sock" --unixsocketperm 700 \
    --save '' --appendonly no >&2 &
  _REDIS_STAGE_PID=$!

  # A loading server answers LOADING, not PONG, for as long as the load takes.
  local deadline=$((SECONDS + REDIS_STAGE_TIMEOUT)) report=$((SECONDS + 10)) perc
  until [[ "$(_stage_cli ping 2>/dev/null)" == PONG ]]; do
    kill -0 "$_REDIS_STAGE_PID" 2>/dev/null ||
      _redis_stage_fail "Staging server exited; the RDB is corrupt, or was written by a newer Redis than this image"
    ((SECONDS < deadline)) ||
      _redis_stage_fail "Staging server still loading after ${REDIS_STAGE_TIMEOUT}s; raise REDIS_STAGE_TIMEOUT for a dataset this size"
    if ((SECONDS >= report)); then
      perc="$(_stage_cli info persistence 2>/dev/null | tr -d '\r' | sed -n 's/^loading_loaded_perc://p')"
      log_info "Staging server is loading the RDB: ${perc:-?}%"
      report=$((SECONDS + 10))
    fi
    sleep "$_REDIS_STAGE_POLL"
  done
}

# Stops the staging server and removes its directory. Safe to call twice, and
# when nothing was started. KILL rather than SHUTDOWN: nothing in it is worth
# a graceful exit, and it may not be answering commands at all.
_redis_stage_stop() {
  if [[ -n "$_REDIS_STAGE_PID" ]]; then
    kill -KILL "$_REDIS_STAGE_PID" 2>/dev/null || true
    wait "$_REDIS_STAGE_PID" 2>/dev/null || true
    _REDIS_STAGE_PID=""
  fi
  if [[ -n "$_REDIS_STAGE_DIR" ]]; then
    rm -rf -- "$_REDIS_STAGE_DIR"
    _REDIS_STAGE_DIR=""
  fi
}

# Every failure after staging begins goes through here, so none of them can
# leave a server holding the dataset or a directory holding the RDB.
_redis_stage_fail() {
  _redis_stage_stop
  die "$1"
}

# A size floor cannot tell a small dataset from a truncated file. Loading it is
# what proves the RDB parses.
backend_verify() {
  _redis_stage "$1" "${BACKUP_DIR:-/tmp}/.verify-$$"
  local keys
  keys="$(_stage_cli dbsize)"
  _redis_stage_stop
  log_info "Staged RDB holds ${keys} keys"
}

backend_restore() {
  local archive="$1"
  local host port password db dir keys batch migrated=0

  # MIGRATE is executed by the staging server against the target, and it has no
  # TLS option — so a rediss:// target cannot be reached this way. Refusing is
  # better than restoring whatever happens to get through.
  if _redis_url_is_tls; then
    die "$(
      cat <<'HINT'
Cannot restore into a TLS target.

MIGRATE runs on the staging server and has no TLS option, so keys cannot be
pushed to a rediss:// endpoint. Use MODE=fetch to retrieve the RDB, then load
it into the server directly: place dump.rdb in its data directory and restart.
HINT
    )"
  fi

  host="$(_redis_url_part host)"
  port="$(_redis_url_part port)"
  password="$(_redis_url_part password)"
  db="$(_redis_url_part db)"

  dir="${BACKUP_DIR:-/tmp}/.restore-$$"
  _redis_stage "$archive" "$dir"

  if bool_is_true RESTORE_FLUSH; then
    log_warn "RESTORE_FLUSH is set — emptying database ${db} on ${host}:${port}"
    _redis -n "$db" flushdb >&2 ||
      _redis_stage_fail "$(
        cat <<'HINT'
FLUSHDB failed. It is very likely disabled on the server rather than broken:
managed Redis and the Bitnami chart both rename FLUSHDB and FLUSHALL away by
default (`rename-command FLUSHDB ""`), so the command comes back as unknown.

Either re-enable it for the restore, or leave RESTORE_FLUSH unset — keys are
written with REPLACE, so the restore still overwrites everything the backup
contains and only leaves keys that are not in it.
HINT
      )"
  fi

  # MIGRATE moves keys in batches, preserving type and TTL. REPLACE overwrites
  # a key that already exists rather than failing the whole batch.
  local -a args=("$host" "$port" '' "$db" "$REDIS_MIGRATE_TIMEOUT_MS")
  [[ -n "$password" ]] && args+=(AUTH "$password")
  args+=(REPLACE KEYS)

  while read -r -a batch && ((${#batch[@]} > 0)); do
    _stage_cli MIGRATE "${args[@]}" "${batch[@]}" >&2 ||
      _redis_stage_fail "MIGRATE failed after ${migrated} keys"
    migrated=$((migrated + ${#batch[@]}))
  done < <(_stage_cli --scan | xargs -n "$REDIS_MIGRATE_BATCH" 2>/dev/null || true)

  _redis_stage_stop
  log_ok "Restored ${migrated} keys into ${host}:${port} db ${db}"
}
