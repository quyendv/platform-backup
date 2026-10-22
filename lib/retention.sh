#!/usr/bin/env bash
# Retention: decide which backup runs to delete.

# A run folder is exactly YYYYMMDD_HHMMSS. Anything else under the prefix belongs
# to someone else and must never be touched.
RUN_ID_PATTERN='^[0-9]{8}_[0-9]{6}$'

# Uploaded last by every run, so its presence is what makes a run a backup.
# shellcheck disable=SC2034 # read by s3.sh and main.sh
COMPLETE_MARKER=_COMPLETE

# prune_select KEEP  < candidate names on stdin, one per line
# Writes the run ids that should be deleted to stdout, newest first.
#
# KEEP=0 disables pruning entirely — it never means "delete everything".
# An empty or fully-filtered listing is success, not failure: callers run under
# `set -o pipefail`, where a bare grep with no match would abort the whole job.
prune_select() {
  local keep="$1"
  if [[ "$keep" -eq 0 ]]; then
    cat >/dev/null
    return 0
  fi
  { grep -E "$RUN_ID_PATTERN" || true; } | sort -r | tail -n "+$((keep + 1))"
}

# prune_select_runs KEEP  < "<run> complete|incomplete" lines on stdin
# Writes the run ids to delete. Only complete runs count toward KEEP: an upload
# that never finished must not evict a real backup. A run without a marker is
# deleted only once KEEP complete runs are newer than it — that covers both a
# failed upload and a run written before markers existed, and never shrinks
# history below KEEP real backups.
prune_select_runs() {
  local keep="$1" lines run state kept=0 oldest=""
  if [[ "$keep" -eq 0 ]]; then
    cat >/dev/null
    return 0
  fi
  lines="$({ grep -E '^[0-9]{8}_[0-9]{6} (complete|incomplete)$' || true; } | sort -r)"
  while read -r run state; do
    [[ "$state" == complete ]] || continue
    if ((kept < keep)); then
      kept=$((kept + 1))
      oldest="$run"
    else
      printf '%s\n' "$run"
    fi
  done <<<"$lines"
  ((kept == keep)) || return 0
  while read -r run state; do
    if [[ "$state" == incomplete && "$run" < "$oldest" ]]; then
      printf '%s\n' "$run"
    fi
  done <<<"$lines"
  return 0
}
