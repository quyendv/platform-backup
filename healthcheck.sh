#!/usr/bin/env bash
# Container healthcheck.
#
# Without this, a scheduled container whose every backup fails still reports
# Up with exit code 0 — the only evidence is a line in the log. This makes the
# outcome visible to docker ps, restart policies, autoheal and anything
# scraping container health.
#
# Unhealthy when the last recorded run failed, or when HEALTHCHECK_MAX_AGE is
# set and the last success is older than that. Deliberately healthy when there
# is no record yet: a container that has only just started has nothing to
# report and must not be killed for it.
set -uo pipefail

STATE_FILE="${STATE_FILE:-${BACKUP_DIR:-/backup}/.last-run.json}"

[[ -r "$STATE_FILE" ]] || exit 0

outcome="$(jq -r '.outcome // empty' "$STATE_FILE" 2>/dev/null)" || exit 0
[[ -n "$outcome" ]] || exit 0

if [[ "$outcome" == "failure" ]]; then
  echo "last backup failed"
  exit 1
fi

# A schedule that silently stops firing looks identical to one that never ran.
# HEALTHCHECK_MAX_AGE (seconds) is how an operator says how long is too long.
max_age="${HEALTHCHECK_MAX_AGE:-0}"
[[ "$max_age" =~ ^[0-9]+$ ]] || exit 0
((max_age > 0)) || exit 0

finished="$(jq -r '.finished_at // empty' "$STATE_FILE" 2>/dev/null)"
[[ -n "$finished" ]] || exit 0

finished_epoch="$(date -u -d "$finished" +%s 2>/dev/null)" || exit 0
age=$(($(date -u +%s) - finished_epoch))

if ((age > max_age)); then
  echo "last successful backup was ${age}s ago, over the ${max_age}s limit"
  exit 1
fi
exit 0
