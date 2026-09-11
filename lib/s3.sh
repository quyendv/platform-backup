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

# s3_list_runs PREFIX -> run ids under the prefix, one per line.
# An empty prefix is success with no output: the first backup of a new target
# lists nothing, and that must not abort the job under `set -o pipefail`.
s3_list_runs() {
  local prefix uri
  prefix="$(normalize_prefix "$1")"
  uri="s3://${S3_BUCKET}/${prefix:+${prefix}/}"
  # `aws s3 ls` on a prefix is already non-recursive and reports child prefixes
  # as "PRE <name>/"; the high-level s3 command has no --delimiter flag at all.
  #
  # Exit status alone cannot be trusted: an empty prefix — what the first ever
  # backup sees — exits 1 with no output, while a missing bucket, a denied
  # policy or bad credentials exit 254 and write to stderr. Discarding stderr
  # turned every one of those into "no backups found", pointing at the wrong
  # problem entirely.
  local out rc=0 errfile
  errfile="$(mktemp)"
  out="$(aws s3 ls "$uri" 2>"$errfile")" || rc=$?
  if ((rc != 0)) && [[ -s "$errfile" ]]; then
    log_error "Cannot list ${uri}: $(tr '\n' ' ' <"$errfile" | head -c 300)"
    rm -f "$errfile"
    return 1
  fi
  rm -f "$errfile"

  # The sed pattern is the filter: only well-formed run folders come through, so
  # anything else living under the prefix is invisible to pruning.
  printf '%s\n' "$out" |
    sed -n 's|^ *PRE \([0-9]\{8\}_[0-9]\{6\}\)/$|\1|p'
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
# s3_upload_run LOCAL_RUN_DIR PREFIX RUN_ID — upload one run folder as a unit.
s3_upload_run() {
  local dir="$1" prefix="$2" run_id="$3" uri
  uri="$(s3_uri "$prefix" "$run_id")"
  if parse_bool "${DRY_RUN:-false}"; then
    log_info "[dry-run] would upload ${dir}/ to ${uri}"
    return 0
  fi
  log_info "Uploading ${dir}/ to ${uri}"
  aws s3 cp "$dir/" "$uri" --recursive --no-progress >&2
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

# prune_remote PREFIX KEEP — apply the retention policy to the object store.
prune_remote() {
  local prefix="$1" keep="$2" runs run
  # Listed first, deliberately: a process substitution's exit status is
  # invisible, so a failed listing used to look exactly like "nothing to
  # prune" and report success for work it never did.
  runs="$(s3_list_runs "$prefix")" || return 1
  while IFS= read -r run; do
    [[ -n "$run" ]] || continue
    s3_delete_run "$prefix" "$run"
  done < <(printf '%s\n' "$runs" | prune_select "$keep")
}

# s3_resolve_run PREFIX [WANTED] -> the run id to restore from.
# With no WANTED, the newest run wins. A WANTED that is not present is an error
# rather than a silent fall back to the newest — restoring a different backup
# than the one asked for is worse than failing.
s3_resolve_run() {
  local prefix="$1" wanted="${2:-}" runs
  # "could not list" and "nothing there" are different problems and must not
  # produce the same message.
  runs="$(s3_list_runs "$prefix")" ||
    {
      log_error "Cannot resolve a run: listing $(s3_uri "$prefix") failed"
      return 1
    }
  runs="$(printf '%s\n' "$runs" | sort -r)"
  if [[ -z "$runs" ]]; then
    log_error "No backup runs found under $(s3_uri "$prefix")"
    return 1
  fi
  if [[ -n "$wanted" ]]; then
    if ! grep -qxF "$wanted" <<<"$runs"; then
      log_error "Requested run ${wanted} not found under $(s3_uri "$prefix")"
      return 1
    fi
    printf '%s' "$wanted"
    return 0
  fi
  printf '%s' "$(head -n1 <<<"$runs")"
}
