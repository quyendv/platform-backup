#!/usr/bin/env bash
# Retention: decide which backup runs to delete.

# A run folder is exactly YYYYMMDD_HHMMSS. Anything else under the prefix belongs
# to someone else and must never be touched.
RUN_ID_PATTERN='^[0-9]{8}_[0-9]{6}$'

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
