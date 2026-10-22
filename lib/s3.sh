#!/usr/bin/env bash
# S3-compatible object storage access.
#
# Credentials, region and endpoint are read by the AWS CLI itself from the
# standard AWS_* variables — this file deliberately does not translate anything
# into them. Leaving them unset is valid and lets an EC2 instance role or an EKS
# service account (IRSA) supply credentials instead.
#
# Addressing style is not configurable on purpose: with a custom endpoint the CLI
# already defaults to path-style (MinIO, Ceph, R2, Spaces), and without one it
# defaults to virtual-hosted (real AWS). No environment variable can change it in
# any case — only `s3.addressing_style` in ~/.aws/config can, so mount that file
# if a provider ever needs the override.
#
# shellcheck source=log.sh

# normalize_prefix PREFIX
# Strips leading/trailing slashes and collapses repeats, so callers can join
# segments with a single slash and never produce an empty key component.
normalize_prefix() {
  local p
  p="$(printf '%s' "$1" | tr -s '/')"
  p="${p#/}"
  p="${p%/}"
  printf '%s' "$p"
}

# s3_key PREFIX RUN_ID FILENAME -> the object key for one artifact.
s3_key() {
  local prefix run_id filename
  prefix="$(normalize_prefix "$1")"
  run_id="$2"
  filename="$3"
  if [[ -n "$prefix" ]]; then
    printf '%s/%s/%s' "$prefix" "$run_id" "$filename"
  else
    printf '%s/%s' "$run_id" "$filename"
  fi
}

# s3_enabled — true when a bucket is configured. An empty S3_BUCKET means
# local-only backups, which is a supported mode, not a misconfiguration.
s3_enabled() {
  [[ -n "${S3_BUCKET:-}" ]]
}

# _s3_list_keys PREFIX -> every object key under the prefix, relative to it,
# one per line. One recursive listing answers both "which runs exist" and
# "which runs are complete"; asking per run would be one request per run.
# An empty prefix is success with no output: the first backup of a new target
# lists nothing, and that must not abort the job under `set -o pipefail`.
_s3_list_keys() {
  local prefix uri
  prefix="$(normalize_prefix "$1")"
  uri="s3://${S3_BUCKET}/${prefix:+${prefix}/}"
  # Exit status alone cannot be trusted: an empty prefix — what the first ever
  # backup sees — exits 1 with no output, while a missing bucket, a denied
  # policy or bad credentials exit 254 and write to stderr. Discarding stderr
  # turned every one of those into "no backups found", pointing at the wrong
  # problem entirely.
  local out rc=0 errfile
  errfile="$(mktemp)"
  out="$(aws s3 ls --recursive "$uri" 2>"$errfile")" || rc=$?
  if ((rc != 0)) && [[ -s "$errfile" ]]; then
    log_error "Cannot list ${uri}: $(tr '\n' ' ' <"$errfile" | head -c 300)"
    rm -f "$errfile"
    return 1
  fi
  rm -f "$errfile"

  # Each line is "<date> <time> <size> <key>", the key being the full one.
  printf '%s\n' "$out" |
    awk -v p="${prefix:+${prefix}/}" '
      NF >= 4 {
        key = $0
        sub(/^[^ ]+ +[^ ]+ +[0-9]+ /, "", key)
        if (index(key, p) == 1) print substr(key, length(p) + 1)
      }'
}

# The sed patterns are the filter: only well-formed run folders come through,
# so anything else living under the prefix is invisible to pruning.
_runs_from_keys() {
  sed -n 's|^\([0-9]\{8\}_[0-9]\{6\}\)/.*|\1|p' | sort -u
}
_complete_runs_from_keys() {
  sed -n "s|^\\([0-9]\\{8\\}_[0-9]\\{6\\}\\)/${COMPLETE_MARKER}\$|\\1|p" | sort -u
}

# s3_list_runs PREFIX -> run ids under the prefix, complete or not, one per line.
s3_list_runs() {
  local keys
  keys="$(_s3_list_keys "$1")" || return 1
  printf '%s\n' "$keys" | _runs_from_keys
}

# s3_list_complete_runs PREFIX -> run ids that carry the completion marker.
s3_list_complete_runs() {
  local keys
  keys="$(_s3_list_keys "$1")" || return 1
  printf '%s\n' "$keys" | _complete_runs_from_keys
}

# s3_uri PREFIX [RUN_ID] -> the s3:// URI for a prefix or one run folder.
s3_uri() {
  local prefix run_id
  prefix="$(normalize_prefix "$1")"
  run_id="${2:-}"
  printf 's3://%s/%s%s' "$S3_BUCKET" "${prefix:+${prefix}/}" "${run_id:+${run_id}/}"
}

# The mutating helpers push the AWS CLI's own progress chatter to stderr: they
# run inside command substitution, where stdout carries the return value.
#
# s3_upload_run LOCAL_RUN_DIR PREFIX RUN_ID — upload one run folder as a unit,
# all but its completion marker, which s3_upload_marker sends last.
s3_upload_run() {
  local dir="$1" prefix="$2" run_id="$3" uri
  uri="$(s3_uri "$prefix" "$run_id")"
  if parse_bool "${DRY_RUN:-false}"; then
    log_info "[dry-run] would upload ${dir}/ to ${uri}"
    return 0
  fi
  log_info "Uploading ${dir}/ to ${uri}"
  aws s3 cp "$dir/" "$uri" --recursive --no-progress --exclude "$COMPLETE_MARKER" >&2
}

# s3_upload_marker LOCAL_RUN_DIR PREFIX RUN_ID — the last object of a run.
# A run without it is not a backup, whatever else made it to the bucket.
s3_upload_marker() {
  local dir="$1" prefix="$2" run_id="$3" uri
  uri="$(s3_uri "$prefix" "$run_id")${COMPLETE_MARKER}"
  if parse_bool "${DRY_RUN:-false}"; then
    log_info "[dry-run] would upload ${uri}"
    return 0
  fi
  aws s3 cp "${dir}/${COMPLETE_MARKER}" "$uri" --no-progress >&2
}

# s3_readback_run LOCAL_RUN_DIR PREFIX RUN_ID — stream every checksummed object
# back from the store and compare it with its local sidecar. Streamed, so it
# needs no second copy on disk; a failed read is a failure, not a pass.
s3_readback_run() {
  local dir="$1" prefix="$2" run_id="$3" sum file want got
  if parse_bool "${DRY_RUN:-false}"; then
    log_info "[dry-run] would read back run ${run_id}"
    return 0
  fi
  while IFS= read -r sum; do
    file="$(basename -- "${sum%.sha256}")"
    want="$(awk '{print $1; exit}' "$sum")"
    got="$(aws s3 cp "$(s3_uri "$prefix" "$run_id")${file}" - | sha256sum | awk '{print $1}')" || {
      log_error "Read-back of ${file} failed"
      return 1
    }
    [[ "$got" == "$want" ]] || {
      log_error "Read-back of ${file} does not match its checksum"
      return 1
    }
    log_ok "Read back ${file}"
  done < <(find "$dir" -maxdepth 1 -type f -name '*.sha256' | sort)
}

# s3_download_run PREFIX RUN_ID DEST_DIR — fetch one run folder as a unit.
s3_download_run() {
  local prefix="$1" run_id="$2" dest="$3" uri
  uri="$(s3_uri "$prefix" "$run_id")"
  mkdir -p "$dest"
  log_info "Downloading ${uri} to ${dest}/"
  aws s3 cp "$uri" "$dest/" --recursive --no-progress >&2
}

# s3_delete_run PREFIX RUN_ID — remove a whole run folder, never a single object.
s3_delete_run() {
  local prefix="$1" run_id="$2" uri
  uri="$(s3_uri "$prefix" "$run_id")"
  if parse_bool "${DRY_RUN:-false}"; then
    log_info "[dry-run] would delete ${uri}"
    return 0
  fi
  log_warn "Pruning remote run ${run_id}"
  aws s3 rm "$uri" --recursive >&2
}

# _run_states KEYS -> "<run> complete|incomplete", one line per run.
_run_states() {
  local keys="$1" complete run
  complete="$(printf '%s\n' "$keys" | _complete_runs_from_keys)"
  while IFS= read -r run; do
    [[ -n "$run" ]] || continue
    if grep -qxF "$run" <<<"$complete"; then
      printf '%s complete\n' "$run"
    else
      printf '%s incomplete\n' "$run"
    fi
  done < <(printf '%s\n' "$keys" | _runs_from_keys)
}

# prune_remote PREFIX KEEP — apply the retention policy to the object store.
prune_remote() {
  local prefix="$1" keep="$2" keys run
  # Listed first, deliberately: a process substitution's exit status is
  # invisible, so a failed listing used to look exactly like "nothing to
  # prune" and report success for work it never did.
  keys="$(_s3_list_keys "$prefix")" || return 1
  while IFS= read -r run; do
    [[ -n "$run" ]] || continue
    s3_delete_run "$prefix" "$run"
  done < <(_run_states "$keys" | prune_select_runs "$keep")
}

# s3_resolve_run PREFIX [WANTED] -> the run id to restore from.
# With no WANTED, the newest complete run wins; a newer run without a marker is
# an upload that never finished. Only where no run has a marker at all (every
# run predates them) does the newest run stand in, with a warning.
# A WANTED that is not present is an error rather than a silent fall back to
# the newest — restoring a different backup than the one asked for is worse
# than failing.
s3_resolve_run() {
  local prefix="$1" wanted="${2:-}" keys runs complete
  # "could not list" and "nothing there" are different problems and must not
  # produce the same message.
  keys="$(_s3_list_keys "$prefix")" ||
    {
      log_error "Cannot resolve a run: listing $(s3_uri "$prefix") failed"
      return 1
    }
  runs="$(printf '%s\n' "$keys" | _runs_from_keys | sort -r)"
  complete="$(printf '%s\n' "$keys" | _complete_runs_from_keys | sort -r)"
  if [[ -z "$runs" ]]; then
    log_error "No backup runs found under $(s3_uri "$prefix")"
    return 1
  fi
  if [[ -n "$wanted" ]]; then
    if ! grep -qxF "$wanted" <<<"$runs"; then
      log_error "Requested run ${wanted} not found under $(s3_uri "$prefix")"
      return 1
    fi
    grep -qxF "$wanted" <<<"$complete" ||
      log_warn "Run ${wanted} has no ${COMPLETE_MARKER} marker; its checksums are still verified"
    printf '%s' "$wanted"
    return 0
  fi
  if [[ -n "$complete" ]]; then
    printf '%s' "$(head -n1 <<<"$complete")"
    return 0
  fi
  log_warn "No run under $(s3_uri "$prefix") has a ${COMPLETE_MARKER} marker; using the newest, which predates them"
  printf '%s' "$(head -n1 <<<"$runs")"
}
