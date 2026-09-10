#!/usr/bin/env bash
# Environment validation. Every backend validates up front so a misconfigured job
# fails before it touches a database or an object store, not halfway through.
#
# shellcheck source=log.sh

# require_env NAME...
# Dies listing every missing variable at once, so one run surfaces the whole
# misconfiguration instead of one variable per attempt.
require_env() {
  local missing=() name
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || missing+=("$name")
  done
  ((${#missing[@]} == 0)) || die "Missing required environment variable(s): ${missing[*]}"
}

# require_int NAME — the named variable must be a non-negative integer.
require_int() {
  local name="$1" value="${!1:-}"
  [[ "$value" =~ ^[0-9]+$ ]] ||
    die "$name must be a non-negative integer (got '${value}')"
}

# parse_bool VALUE
# Returns 0 for true, 1 for false, 2 when the value is neither. Callers must
# treat 2 as a configuration error rather than silently reading it as false.
parse_bool() {
  case "${1,,}" in
    true | 1 | yes | on) return 0 ;;
    false | 0 | no | off | '') return 1 ;;
    *)
      log_error "Expected a boolean value, got '$1'"
      return 2
      ;;
  esac
}

# bool_is_true NAME
# Reads the named variable as a boolean: true -> 0, false or unset -> 1, and a
# value that is neither is fatal. Using parse_bool directly in an `if` would
# read a typo as false, which is the wrong default for flags like RESTORE_DROP.
bool_is_true() {
  local name="$1" value="${!1:-false}"
  parse_bool "$value"
  case $? in
    0) return 0 ;;
    1) return 1 ;;
    *) die "${name} must be a boolean value (got '${value}')" ;;
  esac
}
