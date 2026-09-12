#!/usr/bin/env bash
# The record of what the last run did.
#
# Three things read it: the container healthcheck, the notifier (to tell a new
# failure from an ongoing one, and to announce recovery), and a human asking
# "did last night's backup work" without grepping logs.
#
# Bookkeeping must never turn a good backup into a failed one, so every
# operation here degrades to a warning.
#
# Sourced by lib/main.sh, which has already loaded lib/log.sh and lib/env.sh.

_state_file() {
  printf '%s' "${STATE_FILE:-${BACKUP_DIR:-/backup}/.last-run.json}"
}

# state_write OUTCOME BACKEND RUN_ID ERROR EXIT_CODE [DURATION_SECONDS]
#
# jq builds the document: error text comes from other tools and routinely
# contains quotes, newlines and backslashes, which hand-built JSON mangles.
state_write() {
  local outcome="$1" backend="$2" run_id="$3" error="$4" exit_code="$5"
  local duration="${6:-0}"
  local file tmp
  file="$(_state_file)"

  mkdir -p "$(dirname -- "$file")" 2>/dev/null || true
  tmp="$(mktemp "${file}.XXXXXX" 2>/dev/null)" || {
    log_warn "Cannot write ${file}; continuing without a state record"
    return 0
  }

  if jq -n \
    --arg outcome "$outcome" \
    --arg backend "$backend" \
    --arg run_id "$run_id" \
    --arg error "$error" \
    --arg finished_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson exit_code "$exit_code" \
    --argjson duration_s "$duration" \
    '{schema: 1, outcome: $outcome, backend: $backend, run_id: $run_id,
      error: $error, exit_code: $exit_code, duration_s: $duration_s,
      finished_at: $finished_at}' >"$tmp" 2>/dev/null &&
    mv -- "$tmp" "$file"; then
    return 0
  fi

  rm -f -- "$tmp"
  log_warn "Could not record run state in ${file}"
  return 0
}

# state_previous_outcome -> success | failure | none
# "none" covers both a first run and an unreadable state file: neither is a
# reason to fail, and both mean "no previous outcome to compare against".
state_previous_outcome() {
  local file
  file="$(_state_file)"
  [[ -r "$file" ]] || {
    printf 'none'
    return 0
  }
  jq -r '.outcome // "none"' "$file" 2>/dev/null || printf 'none'
}
