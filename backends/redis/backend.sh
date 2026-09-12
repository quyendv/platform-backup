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

# Staging listens here, not on 6379: a mistake should not reach whatever else
# happens to be listening on the default port.
: "${REDIS_STAGE_PORT:=6399}"

# _redis_stage RDB_GZ DIR
# Decompresses the artifact and starts a throwaway server on it. A corrupt or
# too-new RDB makes redis-server refuse to start, which is the check.
_redis_stage() {
  local archive="$1" dir="$2"
  mkdir -p "$dir"
  gzip -t "$archive" || die "Artifact is not a valid gzip: ${archive}"
  gunzip -c "$archive" >"${dir}/dump.rdb" || die "Could not decompress ${archive}"

  # --save '' so the staging server never writes, and appendonly no so it does
  # not try to replay a journal that is not there.
  redis-server --dir "$dir" --dbfilename dump.rdb \
    --port "$REDIS_STAGE_PORT" --bind 127.0.0.1 \
    --daemonize yes --save '' --appendonly no >&2 || true

  local waited=0
  until redis-cli -p "$REDIS_STAGE_PORT" ping 2>/dev/null | grep -q PONG; do
    waited=$((waited + 1))
    ((waited < 40)) || break
    sleep 0.25
  done
  ((waited < 40)) && return 0
  die "Staging server would not start; the RDB is corrupt, or was written by a newer Redis than this image"
}

_redis_stage_stop() {
  redis-cli -p "$REDIS_STAGE_PORT" shutdown nosave 2>/dev/null || true
}

# A size floor cannot tell a small dataset from a truncated file. Loading it is
# what proves the RDB parses.
backend_verify() {
  local dir="${BACKUP_DIR:-/tmp}/.verify-$$"
  _redis_stage "$1" "$dir"
  local keys
  keys="$(redis-cli -p "$REDIS_STAGE_PORT" dbsize)"
  _redis_stage_stop
  rm -rf -- "$dir"
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
    _redis -n "$db" flushdb >&2 || die "FLUSHDB failed"
  fi

  # MIGRATE moves keys in batches, preserving type and TTL. REPLACE overwrites
  # a key that already exists rather than failing the whole batch.
  local -a args=("$host" "$port" '' "$db" "$REDIS_MIGRATE_TIMEOUT_MS")
  [[ -n "$password" ]] && args+=(AUTH "$password")
  args+=(REPLACE KEYS)

  while read -r -a batch && ((${#batch[@]} > 0)); do
    redis-cli -p "$REDIS_STAGE_PORT" MIGRATE "${args[@]}" "${batch[@]}" >&2 ||
      { _redis_stage_stop && die "MIGRATE failed after ${migrated} keys"; }
    migrated=$((migrated + ${#batch[@]}))
  done < <(redis-cli -p "$REDIS_STAGE_PORT" --scan | xargs -n "$REDIS_MIGRATE_BATCH" 2>/dev/null || true)

  _redis_stage_stop
  rm -rf -- "$dir"
  log_ok "Restored ${migrated} keys into ${host}:${port} db ${db}"
}
