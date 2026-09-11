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
for _m in log env retention checksum s3 local_store state notify; do
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
  bool_is_true DRY_RUN || true
  : "${S3_PREFIX:=backups/$(backend_name)}"
}

_require_bucket() {
  s3_enabled || die "S3_BUCKET is required for MODE=${MODE}"
}

# Only one backup may run at a time per backup directory: a schedule that fires
# faster than a dump completes would otherwise interleave two runs.
_with_lock() {
  local lock="${BACKUP_DIR}/.lock" rc=0
  mkdir -p "$BACKUP_DIR"
  exec 200>"$lock"
  flock -n 200 || die "Another run holds the lock at ${lock}"
  "$@" || rc=$?
  # Release explicitly. Leaving the descriptor open holds the lock for the
  # lifetime of the process, which blocks any later run in the same shell.
  exec 200>&-
  return "$rc"
}

# Discards a run that never became a backup. Called explicitly at each failure
# point rather than from a trap: a RETURN trap fires on every function return,
# and an EXIT trap would clobber whatever the caller installed.
_discard_staging() {
  local staging="$1"
  log_warn "Discarding incomplete run ${staging##*/.staging-}"
  rm -rf -- "$staging"
}

# A floor only catches "the tool produced essentially nothing". It deliberately
# does not try to catch corruption: a real pg_dump of an empty database gzips
# to about 405 bytes, so any floor high enough to notice a truncated dump also
# rejects a legitimate backup. Integrity is backend_verify's job.
: "${MIN_ARTIFACT_BYTES:=128}"

# A run is assembled under .staging-<id> and moved into place only once the
# artifact exists, is big enough and has a checksum. Nothing that fails is ever
# visible as a run directory.
#
# This matters more than it looks: prune keeps the newest N run directories, so
# when a failed run left an empty directory behind, a few failures in a row
# evicted every good backup that came before them.
do_backup() {
  local staging run_dir artifact path size
  RUN_ID="$(date -u '+%Y%m%d_%H%M%S')"
  # The reporting wrapper runs this in a subshell, so the id has to travel out
  # of band for the state record to name the right run.
  [[ -n "${RUN_ID_FILE:-}" ]] && printf '%s' "$RUN_ID" >"$RUN_ID_FILE"
  staging="${BACKUP_DIR}/.staging-${RUN_ID}"
  run_dir="${BACKUP_DIR}/${RUN_ID}"

  # The lock guarantees no other run is active, so any staging directory here
  # belongs to a run that died and is safe to clear.
  rm -rf -- "${BACKUP_DIR:?}"/.staging-*
  mkdir -p "$staging"

  log_info "Backup run ${RUN_ID} for $(backend_name)"
  artifact="$(backend_dump "$staging")" ||
    { _discard_staging "$staging" && die "$(backend_name) dump failed"; }
  path="${staging}/${artifact}"

  [[ -f "$path" ]] ||
    { _discard_staging "$staging" && die "Backend reported ${artifact} but no such file was produced"; }
  size="$(stat -c%s "$path")"
  ((size >= MIN_ARTIFACT_BYTES)) ||
    { _discard_staging "$staging" && die "Backup artifact is implausibly small (${size} bytes, minimum ${MIN_ARTIFACT_BYTES}): ${artifact}"; }
  log_ok "Artifact ${artifact} (${size} bytes)"

  # Optional per-backend integrity check — a truncated archive is the realistic
  # failure, and only the backend's own tooling can spot it.
  if declare -F backend_verify >/dev/null; then
    backend_verify "$path" ||
      { _discard_staging "$staging" && die "Artifact failed $(backend_name) verification: ${artifact}"; }
    log_ok "Verified ${artifact}"
  fi

  write_checksum "$path" ||
    { _discard_staging "$staging" && die "Could not checksum ${artifact}"; }

  # Promotion. After this the run is a real backup; before it, nothing is.
  # Refuse rather than merge: mv into an existing directory would nest the
  # staging directory inside it, which is how two runs in the same second used
  # to corrupt a run folder.
  [[ ! -e "$run_dir" ]] ||
    { _discard_staging "$staging" && die "A run already exists at ${run_dir}"; }
  mv -- "$staging" "$run_dir"

  if s3_enabled; then
    s3_upload_run "$run_dir" "$S3_PREFIX" "$RUN_ID"
    log_ok "Uploaded run ${RUN_ID}"
  else
    log_info "No S3_BUCKET configured — keeping this run locally only"
  fi

  prune_local "$BACKUP_DIR" "$KEEP_LOCAL"
  if s3_enabled; then
    prune_remote "$S3_PREFIX" "$KEEP_REMOTE"
  fi
  log_ok "Backup run ${RUN_ID} complete"
}

# Downloads one run into DEST and verifies it. Echoes the artifact path.
_fetch_into() {
  local dest="$1" run_id file
  run_id="$(s3_resolve_run "$S3_PREFIX" "$RESTORE_TIMESTAMP")" ||
    die "Cannot resolve a backup run to restore"
  log_info "Selected run ${run_id}"
  s3_download_run "$S3_PREFIX" "$run_id" "${dest}/${run_id}"

  # The checksum sidecar identifies the artifact. Picking "the first file that
  # is not a .sha256" depended on directory order, which is not guaranteed —
  # it chose a different file on a CI runner than it did locally. It also
  # makes the sidecar the marker of a complete run: half an upload has one
  # without the other, and is rejected here rather than part-way through a
  # restore.
  #
  # -print -quit rather than a pipe into head: under pipefail, head closing
  # the pipe early kills find with SIGPIPE and the pipeline returns 141.
  local sum
  sum="$(find "${dest}/${run_id}" -maxdepth 1 -type f -name '*.sha256' -print -quit)"
  [[ -n "$sum" ]] || die "Run ${run_id} has no checksum; it is not a complete backup"
  file="${sum%.sha256}"
  [[ -f "$file" ]] ||
    die "Run ${run_id} has a checksum but no artifact; the upload was incomplete"
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

# Records the outcome and notifies, whatever happened. Wrapping main rather
# than scattering calls through it means there is exactly one place where a
# run's result is decided, and no path that forgets to report.
_run_and_report() {
  local started previous rc=0 err_file error=""
  local RUN_ID_FILE
  started="$(date +%s)"
  previous="$(state_previous_outcome)"
  err_file="$(mktemp)"

  # A subshell, because die() exits: run it in this shell and the exit unwinds
  # past the reporting below, which is exactly how a failed run used to leave
  # no record at all.
  #
  # stderr goes through a pipe rather than a process substitution so the shell
  # waits for tee to finish before the file is read, while the operator still
  # sees output live during a long dump.
  RUN_ID_FILE="$(mktemp)"
  # `set +e` here only stops the parent aborting before PIPESTATUS can be read.
  # The subshell turns errexit back on: without that, the whole run executed
  # without it, and a failed pg_dump surfaced as "artifact too small" three
  # steps later instead of as a dump failure.
  set +e
  { (
    set -e
    _dispatch_mode
  ) 2>&1 1>&3 | tee -a "$err_file" >&2; } 3>&1
  rc="${PIPESTATUS[0]}"
  set -e
  RUN_ID="$(cat "$RUN_ID_FILE" 2>/dev/null || true)"
  rm -f -- "$RUN_ID_FILE"

  if ((rc != 0)); then
    # First, not last: the earliest error is the cause, anything after it is
    # the driver unwinding.
    error="$(grep -a '\[ERROR\]' "$err_file" | head -n1 | sed 's/.*\[ERROR\] *//')"
    [[ -n "$error" ]] || error="exited with status ${rc}"
  fi
  rm -f -- "$err_file"

  state_write "$( ((rc == 0)) && printf success || printf failure)" \
    "$(backend_name)" "${RUN_ID:-}" "$error" "$rc" "$(($(date +%s) - started))"

  notify_run "$( ((rc == 0)) && printf success || printf failure)" \
    "$(backend_name)" "${RUN_ID:-}" "$error" "$rc" "$previous"

  return "$rc"
}

_dispatch_mode() {
  case "$MODE" in
    backup) _with_lock do_backup ;;
    fetch) do_fetch ;;
    restore) do_restore ;;
  esac
}

main() {
  : "${MODE:=backup}"
  # MODE is checked before anything else. Validating the backend first meant a
  # typo in MODE surfaced as whatever env that backend happened to require,
  # pointing at the wrong problem.
  case "$MODE" in
    backup | fetch | restore) ;;
    *) die "Unknown MODE '${MODE}' (expected backup, fetch or restore)" ;;
  esac

  _validate_common
  backend_validate

  _run_and_report
}
