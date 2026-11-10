#!/usr/bin/env bash
# PostgreSQL adapter: pg_dump in custom format, gzipped.
#
# The image tag must match the server major version — pg_dump refuses to dump a
# server newer than itself, which is why this backend is built as a matrix.
#
# Sourced by lib/main.sh, which has already loaded lib/log.sh and lib/env.sh.

backend_name() { printf 'postgresql'; }
backend_caps() { printf 'fetch restore migrate'; }

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
  : "${POSTGRES_DUMP_GLOBALS:=true}"
  : "${RESTORE_GLOBALS:=false}"
  : "${RESTORE_CREATE:=false}"
  : "${RESTORE_NO_OWNER:=false}"
  bool_is_true POSTGRES_DUMP_GLOBALS || true
  bool_is_true RESTORE_GLOBALS || true
  bool_is_true RESTORE_CREATE || true
  bool_is_true RESTORE_NO_OWNER || true
  if [[ "${MODE:-backup}" == restore ]] && bool_is_true RESTORE_CREATE && bool_is_true RESTORE_CLEAN; then
    die "RESTORE_CREATE and RESTORE_CLEAN cannot both be true in restore mode"
  fi
  if [[ "${MODE:-backup}" == migrate ]]; then
    require_env DEST_POSTGRES_HOST DEST_POSTGRES_USER DEST_POSTGRES_PASSWORD DEST_POSTGRES_DB
    : "${DEST_POSTGRES_PORT:=5432}"
    : "${DEST_POSTGRES_MAINTENANCE_DB:=postgres}"
    : "${MIGRATE_DROP:=false}"
    : "${MIGRATE_VERIFY:=true}"
    bool_is_true MIGRATE_DROP || true
    bool_is_true MIGRATE_VERIFY || true
    # Used literally in SQL, so a connection string would name a different database there.
    if [[ "$DEST_POSTGRES_DB" == *=* || "$DEST_POSTGRES_DB" == *://* ]]; then
      die "DEST_POSTGRES_DB must be a plain database name, not a connection string"
    fi
    if bool_is_true RESTORE_CREATE && [[ "$POSTGRES_DB" != "$DEST_POSTGRES_DB" ]]; then
      die "RESTORE_CREATE requires equal source and destination database names"
    fi
  fi
}

# _is_superuser — only a superuser can read role passwords.
_is_superuser() {
  local args=() answer
  mapfile -t args < <(_conn_args)
  answer="$(psql "${args[@]}" --no-password -d "$POSTGRES_DB" -tAc \
    'SELECT rolsuper FROM pg_roles WHERE rolname = current_user')" || return 1
  [[ "$answer" == t ]]
}

# _dump_globals DIR — roles, memberships and tablespaces, which pg_dump never
# carries. Without them a restore to a fresh server has the tables and none of
# the roles that own or read them.
_dump_globals() {
  local dir="$1" name="globals-${RUN_ID}.sql.gz"
  local args=() extra=()
  mapfile -t args < <(_conn_args)
  if ! _is_superuser; then
    log_info "Not a superuser: globals are dumped without role passwords"
    extra=(--no-role-passwords)
  fi
  # -l: connect to the database being backed up, which pg_hba already admits,
  # rather than to "postgres", which it may not.
  pg_dumpall "${args[@]}" --no-password -l "$POSTGRES_DB" --globals-only "${extra[@]}" |
    gzip >"${dir}/${name}" ||
    die "pg_dumpall --globals-only failed on ${POSTGRES_HOST}"
  gzip -t "${dir}/${name}" || die "The globals dump is not a valid gzip stream"
  log_ok "Globals ${name}"
}

backend_dump() {
  local dir="$1" name="postgresql-${RUN_ID}.dump.gz"
  local args=()
  mapfile -t args < <(_conn_args)

  # Without -d the server looks for a database named after the user, and logs a FATAL.
  pg_isready "${args[@]}" -d "$POSTGRES_DB" -q ||
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

  if bool_is_true POSTGRES_DUMP_GLOBALS; then
    _dump_globals "$dir"
  fi

  printf '%s' "$name"
}

# pg_restore --list parses the archive's table of contents, so it fails on a
# truncated or corrupt dump while accepting a valid dump of an empty database.
#
# It stops reading once it has the table of contents. The rest of the stream is
# drained after it exits, or gunzip dies of SIGPIPE on any dump larger than a
# pipe buffer and pipefail fails the run. gzip -t has already read every byte.
backend_verify() {
  local file="$1"
  gzip -t "$file" || return 1
  gunzip -c "$file" | {
    local rc=0
    pg_restore --list >/dev/null || rc=$?
    cat >/dev/null
    return "$rc"
  }
}

# Drain after --list, as in backend_verify, to keep gunzip from receiving SIGPIPE.
_archive_database() {
  gunzip -c "$1" | {
    local rc=0 listing
    listing="$(pg_restore --list)" || rc=$?
    cat >/dev/null
    [[ "$rc" -eq 0 ]] || return "$rc"
    printf '%s\n' "$listing" | sed -n 's/^;[[:space:]]*dbname: //p'
  }
}

# _without_role NAME < globals — drops the CREATE ROLE and ALTER ROLE lines of
# one role, whether pg_dumpall quoted its name or not. Memberships stay.
_without_role() {
  awk -v plain="$1" '
    function names(line, id, n, c) {
      n = length(id)
      c = substr(line, n + 1, 1)
      return substr(line, 1, n) == id && (c == " " || c == ";" || c == "")
    }
    BEGIN { quoted = plain; gsub(/"/, "\"\"", quoted); quoted = "\"" quoted "\"" }
    /^(CREATE|ALTER) ROLE / {
      id = $0
      sub(/^[A-Z]+ ROLE /, "", id)
      if (names(id, plain) || names(id, quoted)) next
    }
    { print }'
}

backend_restore() {
  local file="$1"
  local args=()
  mapfile -t args < <(_conn_args)
  args+=(--no-password)

  if bool_is_true RESTORE_CREATE; then
    local archive_db exists
    archive_db="$(_archive_database "$file")" || die "pg_restore --list failed while reading the archive database name"
    [[ "$archive_db" == "$POSTGRES_DB" ]] ||
      die "Archive database '${archive_db}' differs from POSTGRES_DB='${POSTGRES_DB}'; unset RESTORE_CREATE to restore under another name"
    if ! bool_is_true RESTORE_DROP; then
      exists="$(
        psql "${args[@]}" -d "$POSTGRES_MAINTENANCE_DB" -tA -v ON_ERROR_STOP=1 -v name="$POSTGRES_DB" <<'SQL'
SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'name');
SQL
      )" || die "psql failed checking whether database '${POSTGRES_DB}' exists"
      [[ "$exists" == f ]] ||
        die "Database '${POSTGRES_DB}' already exists with RESTORE_DROP=${RESTORE_DROP:-false}; set RESTORE_DROP=true to replace it"
    fi
  fi

  if bool_is_true RESTORE_DROP; then
    local create_database=""
    if ! bool_is_true RESTORE_CREATE; then
      create_database="CREATE DATABASE \"${POSTGRES_DB}\";"
      log_info "Plain RESTORE_DROP: owner, encoding, grants and database-level settings are not restored; RESTORE_CREATE restores them"
    fi
    log_warn "RESTORE_DROP is set — dropping and recreating ${POSTGRES_DB}"
    psql "${args[@]}" -d "$POSTGRES_MAINTENANCE_DB" -v ON_ERROR_STOP=1 -q <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
 WHERE datname = '${POSTGRES_DB}' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS "${POSTGRES_DB}";
${create_database}
SQL
  fi

  # Opt-in: on a live server the backed-up roles would overwrite any changed
  # since. On a fresh one they are what the restored objects' grants need.
  local globals
  globals="$(dirname -- "$file")/globals-$(basename -- "$file" | sed -n 's/^postgresql-\([0-9_]*\)\..*/\1/p').sql.gz"
  if bool_is_true RESTORE_GLOBALS; then
    [[ -f "$globals" ]] || die "RESTORE_GLOBALS is set but the run has no $(basename -- "$globals")"
    log_info "Applying $(basename -- "$globals"); roles that already exist are reported and kept"
    # Without the connecting role's own CREATE and ALTER ROLE: a superuser's
    # globals carry its password, and applying it would lock this restore out
    # of the server before pg_restore connects.
    gunzip -c "$globals" | _without_role "$POSTGRES_USER" |
      psql "${args[@]}" -d "$POSTGRES_MAINTENANCE_DB" -q ||
      die "Applying the globals failed"
  fi

  local restore_args=("${args[@]}" -d "$POSTGRES_DB")
  if bool_is_true RESTORE_CREATE; then
    restore_args=("${args[@]}" -d "$POSTGRES_MAINTENANCE_DB" --create)
  fi
  if bool_is_true RESTORE_NO_OWNER; then
    restore_args+=(--no-owner --no-acl)
  fi
  if bool_is_true RESTORE_CLEAN; then
    restore_args+=(--clean --if-exists)
  fi

  log_info "pg_restore: $(pg_restore --version)"
  gunzip -c "$file" | pg_restore "${restore_args[@]}"
}

# Exact counts use server-side identifier quoting and a fixed client encoding and order.
_migrate_counts() {
  PGCLIENTENCODING=UTF8 psql "$@" --no-password -tA -v ON_ERROR_STOP=1 <<'SQL'
SELECT command FROM (
  SELECT format('SELECT %L, count(*) FROM %I.%I;',
    format('%I.%I', ns.nspname, c.relname), ns.nspname, c.relname) AS command,
    format('%I.%I', ns.nspname, c.relname) AS name
  FROM pg_class c JOIN pg_namespace ns ON ns.oid=c.relnamespace
  WHERE c.relkind='r' AND ns.nspname NOT IN ('pg_catalog', 'information_schema')
    AND ns.nspname !~ '^pg_toast' AND ns.nspname !~ '^pg_temp'
  UNION ALL
  SELECT 'SELECT ''<large objects>'', count(*) FROM pg_largeobject_metadata;', '<large objects>'
) commands ORDER BY name COLLATE "C"
\gexec
SQL
}

backend_migrate() {
  local source=() dest=() source_start dest_start source_name exists nonempty
  mapfile -t source < <(_conn_args)
  # shellcheck disable=SC2153
  dest=(-h "$DEST_POSTGRES_HOST" -p "$DEST_POSTGRES_PORT" -U "$DEST_POSTGRES_USER")
  pg_isready "${source[@]}" -d "$POSTGRES_DB" -q || die "pg_isready failed for the source"
  PGPASSWORD="$DEST_POSTGRES_PASSWORD" pg_isready "${dest[@]}" -d "$DEST_POSTGRES_MAINTENANCE_DB" -q ||
    die "pg_isready failed for the destination"
  source_start="$(
    psql "${source[@]}" --no-password -d "$POSTGRES_DB" -tA -v ON_ERROR_STOP=1 <<'SQL'
SELECT extract(epoch FROM pg_postmaster_start_time());
SQL
  )" || die "psql failed querying source postmaster identity"
  dest_start="$(
    PGPASSWORD="$DEST_POSTGRES_PASSWORD" psql "${dest[@]}" --no-password -d "$DEST_POSTGRES_MAINTENANCE_DB" -tA -v ON_ERROR_STOP=1 <<'SQL'
SELECT extract(epoch FROM pg_postmaster_start_time());
SQL
  )" || die "psql failed querying destination postmaster identity"
  # The connected name: POSTGRES_DB may be a libpq connection string.
  source_name="$(
    psql "${source[@]}" --no-password -d "$POSTGRES_DB" -tA -v ON_ERROR_STOP=1 <<'SQL'
SELECT current_database();
SQL
  )" || die "psql failed querying the source database name"
  if [[ "$source_start" == "$dest_start" && "$source_name" == "$DEST_POSTGRES_DB" ]]; then
    die "Migration refused: source and destination are the same database"
  fi
  exists="$(
    PGPASSWORD="$DEST_POSTGRES_PASSWORD" psql "${dest[@]}" --no-password -d "$DEST_POSTGRES_MAINTENANCE_DB" -tA -v ON_ERROR_STOP=1 -v name="$DEST_POSTGRES_DB" <<'SQL'
SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'name');
SQL
  )" || die "psql failed checking destination database existence"
  if [[ "$exists" == t ]] && ! bool_is_true MIGRATE_DROP; then
    nonempty="$(
      PGPASSWORD="$DEST_POSTGRES_PASSWORD" psql "${dest[@]}" --no-password -d "$DEST_POSTGRES_DB" -tA -v ON_ERROR_STOP=1 <<'SQL'
SELECT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE c.relkind IN ('r','p','v','m','S','f')
 AND n.nspname NOT IN ('pg_catalog','information_schema')
 AND n.nspname !~ '^pg_toast' AND n.nspname !~ '^pg_temp'
 AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid='pg_class'::regclass
   AND d.objid=c.oid AND d.deptype='e'));
SQL
    )" || die "psql failed checking destination database emptiness"
    [[ "$nonempty" == f ]] || die "Destination database is non-empty; MIGRATE_DROP=true is required to replace it"
    if bool_is_true RESTORE_CREATE; then
      die "RESTORE_CREATE requires an absent destination database or MIGRATE_DROP=true"
    fi
  fi

  if bool_is_true MIGRATE_DROP; then
    log_warn "MIGRATE_DROP is set: terminating sessions and dropping the destination database"
    PGPASSWORD="$DEST_POSTGRES_PASSWORD" psql "${dest[@]}" --no-password -d "$DEST_POSTGRES_MAINTENANCE_DB" -q -v ON_ERROR_STOP=1 -v name="$DEST_POSTGRES_DB" <<'SQL' || die "psql failed dropping the destination database"
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
 WHERE datname = :'name' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS :"name";
SQL
    exists=f
  fi
  local codes=() globals_extra=()
  if bool_is_true RESTORE_GLOBALS; then
    if ! _is_superuser; then globals_extra+=(--no-role-passwords); fi
    log_info "Applying globals; roles that already exist are reported and kept"
    if pg_dumpall "${source[@]}" --no-password -l "$POSTGRES_DB" --globals-only "${globals_extra[@]}" |
      _without_role "$DEST_POSTGRES_USER" |
      PGPASSWORD="$DEST_POSTGRES_PASSWORD" psql "${dest[@]}" --no-password -d "$DEST_POSTGRES_MAINTENANCE_DB" -q; then
      codes=("${PIPESTATUS[@]}")
    else
      codes=("${PIPESTATUS[@]}")
    fi
    ((codes[0] == 0)) || die "pg_dumpall failed streaming globals"
    ((codes[1] == 0)) || die "Filtering globals failed"
    ((codes[2] == 0)) || die "psql failed applying globals"
  fi
  if ! bool_is_true RESTORE_CREATE && [[ "$exists" == f ]]; then
    log_info "Creating an empty destination: owner, encoding, grants and database-level settings are not carried; RESTORE_CREATE carries them"
    PGPASSWORD="$DEST_POSTGRES_PASSWORD" psql "${dest[@]}" --no-password -d "$DEST_POSTGRES_MAINTENANCE_DB" -q -v ON_ERROR_STOP=1 -v name="$DEST_POSTGRES_DB" <<'SQL' || die "psql failed creating the destination database"
CREATE DATABASE :"name";
SQL
  fi
  local restore=("${dest[@]}" --no-password -d "$DEST_POSTGRES_DB")
  if bool_is_true RESTORE_CREATE; then
    restore=("${dest[@]}" --no-password -d "$DEST_POSTGRES_MAINTENANCE_DB" --create)
  fi
  if bool_is_true RESTORE_NO_OWNER; then restore+=(--no-owner --no-acl); fi
  if pg_dump "${source[@]}" --no-password -d "$POSTGRES_DB" --format=custom |
    PGPASSWORD="$DEST_POSTGRES_PASSWORD" pg_restore "${restore[@]}"; then
    codes=("${PIPESTATUS[@]}")
  else
    codes=("${PIPESTATUS[@]}")
  fi
  if ((codes[0] != 0)); then log_error "pg_dump failed streaming the source database (exit ${codes[0]})"; fi
  if ((codes[1] != 0)); then log_error "pg_restore failed restoring the destination database (exit ${codes[1]})"; fi
  ((codes[0] == 0 && codes[1] == 0)) || die "Database migration stream failed"
  if bool_is_true MIGRATE_VERIFY; then
    local source_counts dest_counts differences
    source_counts="$(_migrate_counts "${source[@]}" -d "$POSTGRES_DB" -q)" || die "psql failed counting source rows"
    dest_counts="$(PGPASSWORD="$DEST_POSTGRES_PASSWORD" _migrate_counts "${dest[@]}" -d "$DEST_POSTGRES_DB" -q)" || die "psql failed counting destination rows"
    if [[ "$source_counts" != "$dest_counts" ]]; then
      differences="$(diff -u <(printf '%s\n' "$source_counts") <(printf '%s\n' "$dest_counts") | sed -n '/^[+-][^+-]/p' | sed -n '1,20p' || true)"
      log_error "Migration verification differs (up to 20 entries): ${differences}"
      die "A still-written source is the usual cause of differing row counts"
    fi
  fi
}
