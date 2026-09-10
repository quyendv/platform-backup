#!/usr/bin/env bash
# Structured logging, shared by every backend.
#
# Everything goes to stderr. stdout is reserved for data: backend_dump echoes the
# artifact filename and _fetch_into echoes a path, both read by command
# substitution, so a stray log line on stdout would silently corrupt the value.
#
# Colour is enabled only on a TTY: these images normally run under cron or as a
# Kubernetes Job, where ANSI escapes just make the collected logs harder to read.

if [[ -t 2 ]]; then
  readonly _C_INFO=$'\033[0;36m' _C_OK=$'\033[0;32m' _C_WARN=$'\033[1;33m' _C_ERR=$'\033[0;31m' _C_OFF=$'\033[0m'
else
  readonly _C_INFO='' _C_OK='' _C_WARN='' _C_ERR='' _C_OFF=''
fi

_log_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

log_info() { printf '%s %s[INFO ]%s %s\n' "$(_log_ts)" "$_C_INFO" "$_C_OFF" "$*" >&2; }
log_ok() { printf '%s %s[OK   ]%s %s\n' "$(_log_ts)" "$_C_OK" "$_C_OFF" "$*" >&2; }
log_warn() { printf '%s %s[WARN ]%s %s\n' "$(_log_ts)" "$_C_WARN" "$_C_OFF" "$*" >&2; }
log_error() { printf '%s %s[ERROR]%s %s\n' "$(_log_ts)" "$_C_ERR" "$_C_OFF" "$*" >&2; }

die() {
  log_error "$@"
  exit 1
}
