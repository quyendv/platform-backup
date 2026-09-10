#!/usr/bin/env bash
# Container entrypoint, shared by all four images.
#
# Dispatch, in order:
#   `entrypoint.sh run`  -> one run, ignoring SCHEDULE (this is what cron calls)
#   MODE=fetch|restore   -> one run, ignoring SCHEDULE
#   SCHEDULE set         -> hand over to supercronic
#   otherwise            -> one run
set -euo pipefail

APP_DIR="${APP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# shellcheck source=lib/main.sh
source "${APP_DIR}/lib/main.sh"
# shellcheck source=/dev/null
source "${APP_DIR}/backend.sh"

MODE="$(printf '%s' "${MODE:-backup}" | tr '[:upper:]' '[:lower:]')"
export MODE

if [[ "${1:-}" == "run" ]]; then
  main
  exit $?
fi

if [[ "$MODE" != "backup" ]]; then
  log_info "MODE=${MODE} — running once"
  main
  exit $?
fi

if [[ -n "${SCHEDULE:-}" ]]; then
  CRONTAB="${CRONTAB_PATH:-/tmp/crontab}"
  printf '%s %s run\n' "$SCHEDULE" "${APP_DIR}/entrypoint.sh" >"$CRONTAB"
  log_info "SCHEDULE='${SCHEDULE}' — starting supercronic"
  exec supercronic -passthrough-logs "$CRONTAB"
fi

log_info "No SCHEDULE set — running once"
main
