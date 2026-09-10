#!/usr/bin/env bash
# The driver. Every backend runs this exact flow; the adapter only supplies the
# four or five hooks in backends/<name>/backend.sh.
#
# shellcheck source=log.sh
# shellcheck source=env.sh
# shellcheck source=s3.sh
# shellcheck source=checksum.sh
# shellcheck source=retention.sh
# shellcheck source=local_store.sh

_LIB_DIR="${_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck disable=SC1091
for _m in log env retention checksum s3 local_store; do
  source "${_LIB_DIR}/${_m}.sh"
done
unset _m

# Defaults. Documented in docs/backends/<name>.md and each .env.example.
: "${MODE:=backup}"
: "${BACKUP_DIR:=/backup}"
: "${RESTORE_DIR:=/restore}"
: "${KEEP_LOCAL:=3}"
: "${KEEP_REMOTE:=30}"
: "${DRY_RUN:=false}"
: "${S3_BUCKET:=}"
: "${RESTORE_TIMESTAMP:=}"

backend_supports() {
  local want="$1"
  [[ " $(backend_caps) " == *" ${want} "* ]]
}

_validate_common() {
  require_int KEEP_LOCAL
  require_int KEEP_REMOTE
  parse_bool "$DRY_RUN" || [[ $? -eq 1 ]] || die "DRY_RUN must be a boolean"
  : "${S3_PREFIX:=backups/$(backend_name)}"
}

_require_bucket() {
  s3_enabled || die "S3_BUCKET is required for MODE=${MODE}"
}

# Only one backup may run at a time per backup directory: a schedule that fires
# faster than a dump completes would otherwise interleave two runs.
_with_lock() {
  local lock="${BACKUP_DIR}/.lock"
  mkdir -p "$BACKUP_DIR"
  exec 200>"$lock"
  flock -n 200 || die "Another run holds the lock at ${lock}"
  "$@"
}

do_backup() {
  local run_dir artifact path size
  RUN_ID="$(date -u '+%Y%m%d_%H%M%S')"
  run_dir="${BACKUP_DIR}/${RUN_ID}"
  mkdir -p "$run_dir"

  log_info "Backup run ${RUN_ID} for $(backend_name)"
  artifact="$(backend_dump "$run_dir")"
  path="${run_dir}/${artifact}"

  [[ -f "$path" ]] || die "Backend reported ${artifact} but no such file was produced"
  size="$(stat -c%s "$path")"
  ((size > 0)) || die "Backup artifact is empty: ${artifact}"
  log_ok "Artifact ${artifact} (${size} bytes)"

  write_checksum "$path"

  if s3_enabled; then
    s3_upload_run "$run_dir" "$S3_PREFIX" "$RUN_ID"
    log_ok "Uploaded run ${RUN_ID}"
  else
    log_info "No S3_BUCKET configured — keeping this run locally only"
  fi

  prune_local "$BACKUP_DIR" "$KEEP_LOCAL"
  s3_enabled && prune_remote "$S3_PREFIX" "$KEEP_REMOTE"
  log_ok "Backup run ${RUN_ID} complete"
}

# Downloads one run into DEST and verifies it. Echoes the artifact path.
_fetch_into() {
  local dest="$1" run_id file
  run_id="$(s3_resolve_run "$S3_PREFIX" "$RESTORE_TIMESTAMP")" ||
    die "Cannot resolve a backup run to restore"
  log_info "Selected run ${run_id}"
  s3_download_run "$S3_PREFIX" "$run_id" "${dest}/${run_id}"

  file="$(find "${dest}/${run_id}" -maxdepth 1 -type f ! -name '*.sha256' | head -n1)"
  [[ -n "$file" ]] || die "Run ${run_id} contains no artifact"
  verify_checksum "$file" || die "Checksum verification failed for ${file}"
  log_ok "Verified $(basename "$file")"
  printf '%s' "$file"
}

do_fetch() {
  _require_bucket
  local file
  file="$(_fetch_into "$RESTORE_DIR")"
  log_ok "Artifact available at ${file}"
}

do_restore() {
  _require_bucket
  if ! backend_supports restore; then
    log_error "$(backend_name) does not support MODE=restore in this image."
    if declare -F backend_restore_hint >/dev/null; then
      backend_restore_hint >&2
    fi
    exit 1
  fi
  local file
  file="$(_fetch_into "$RESTORE_DIR")"
  log_info "Restoring from $(basename "$file")"
  backend_restore "$file"
  log_ok "Restore complete"
}

main() {
  : "${MODE:=backup}"
  _validate_common
  backend_validate

  case "$MODE" in
    backup) _with_lock do_backup ;;
    fetch) do_fetch ;;
    restore) do_restore ;;
    *) die "Unknown MODE '${MODE}' (expected backup, fetch or restore)" ;;
  esac
}
