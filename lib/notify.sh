#!/usr/bin/env bash
# Outbound notifications.
#
# A channel is enabled by the presence of its own variables — there is no list
# to keep in sync — and every configured channel is attempted. Nothing in here
# may change the outcome of a backup: a dead Slack must not fail a run, so each
# send is isolated and the dispatcher always returns 0.
#
# jq builds every payload. Error text comes from other tools and routinely
# contains quotes, newlines and backslashes; hand-built JSON mangles it and, on
# a webhook, would let that text escape its own field.
#
# Sourced by lib/main.sh, which has already loaded lib/log.sh and lib/env.sh.

: "${NOTIFY_ON:=failure}"
: "${NOTIFY_TIMEOUT:=15}"
: "${NOTIFY_TELEGRAM_API_BASE:=https://api.telegram.org}"
# Chat services cap message length — Telegram rejects over 4096 with a 400,
# Discord over 2000 — and a verbose dump failure is exactly when the message
# matters most. The error is capped for chat; the webhook and email keep it
# whole, because those are read by machines and by people who can scroll.
: "${NOTIFY_MAX_ERROR_CHARS:=900}"

# notify_should_send OUTCOME PREVIOUS_OUTCOME
#   0 send, 1 stay quiet, 2 misconfigured
#
#   never    nothing
#   change   transitions only: the first failure, and the recovery
#   failure  every failure, plus the recovery (default)
#   always   every run
notify_should_send() {
  local outcome="$1" previous="$2"
  case "${NOTIFY_ON}" in
    never) return 1 ;;
    always) return 0 ;;
    change)
      [[ "$outcome" != "$previous" ]] && return 0
      return 1
      ;;
    failure)
      [[ "$outcome" == "failure" ]] && return 0
      # The first success after a failure: without it you never learn the
      # problem went away.
      [[ "$outcome" == "success" && "$previous" == "failure" ]] && return 0
      return 1
      ;;
    *)
      log_error "NOTIFY_ON must be never, change, failure or always (got '${NOTIFY_ON}')"
      return 2
      ;;
  esac
}

# notify_channels -> names of the channels that are configured, one per line.
notify_channels() {
  [[ -n "${NOTIFY_SLACK_WEBHOOK_URL:-}" ]] && printf 'slack\n'
  [[ -n "${NOTIFY_GOOGLE_CHAT_WEBHOOK_URL:-}" ]] && printf 'google_chat\n'
  [[ -n "${NOTIFY_DISCORD_WEBHOOK_URL:-}" ]] && printf 'discord\n'
  [[ -n "${NOTIFY_TELEGRAM_BOT_TOKEN:-}" && -n "${NOTIFY_TELEGRAM_CHAT_ID:-}" ]] &&
    printf 'telegram\n'
  [[ -n "${NOTIFY_WEBHOOK_URL:-}" ]] && printf 'webhook\n'
  [[ -n "${NOTIFY_SMTP_URL:-}" && -n "${NOTIFY_SMTP_FROM:-}" && -n "${NOTIFY_SMTP_TO:-}" ]] &&
    printf 'smtp\n'
  return 0
}

_notify_subject() {
  local outcome="$1" backend="$2"
  case "$outcome" in
    failure) printf '[BACKUP FAILED] %s' "$backend" ;;
    recovered) printf '[BACKUP RECOVERED] %s' "$backend" ;;
    *) printf '[BACKUP OK] %s' "$backend" ;;
  esac
}

_notify_truncate() {
  local text="$1" limit="$2"
  if ((${#text} > limit)); then
    printf '%s… (truncated, %d characters)' "${text:0:limit}" "${#text}"
  else
    printf '%s' "$text"
  fi
}

_notify_text() {
  local outcome="$1" backend="$2" run_id="$3" error="$4" exit_code="$5"
  printf '%s\nhost: %s\nrun: %s' \
    "$(_notify_subject "$outcome" "$backend")" "$(hostname)" "${run_id:-n/a}"
  [[ "$outcome" == "failure" ]] &&
    printf '\nexit: %s\nerror: %s' "$exit_code" \
      "$(_notify_truncate "${error:-unknown}" "$NOTIFY_MAX_ERROR_CHARS")"
  return 0
}

# A URL is a credential for most of these channels, so failures name the
# channel and never the endpoint.
_notify_post_json() {
  local channel="$1" url="$2" payload="$3"
  curl -fsS --max-time "$NOTIFY_TIMEOUT" \
    -X POST -H 'Content-Type: application/json' \
    --data "$payload" "$url" >/dev/null 2>&1 ||
    log_warn "Notification via ${channel} failed"
}

_notify_slack() {
  _notify_post_json slack "$NOTIFY_SLACK_WEBHOOK_URL" \
    "$(jq -n --arg t "$1" '{text: $t}')"
}

_notify_google_chat() {
  _notify_post_json google_chat "$NOTIFY_GOOGLE_CHAT_WEBHOOK_URL" \
    "$(jq -n --arg t "$1" '{text: $t}')"
}

_notify_discord() {
  _notify_post_json discord "$NOTIFY_DISCORD_WEBHOOK_URL" \
    "$(jq -n --arg t "$1" '{content: $t}')"
}

_notify_telegram() {
  local text="$1"
  _notify_post_json telegram \
    "${NOTIFY_TELEGRAM_API_BASE}/bot${NOTIFY_TELEGRAM_BOT_TOKEN}/sendMessage" \
    "$(jq -n --arg c "$NOTIFY_TELEGRAM_CHAT_ID" --arg t "$text" \
      '{chat_id: $c, text: $t}')"
}

# Structured, not prose: this one feeds other software.
_notify_webhook() {
  local outcome="$1" backend="$2" run_id="$3" error="$4" exit_code="$5"
  _notify_post_json webhook "$NOTIFY_WEBHOOK_URL" \
    "$(jq -cn \
      --arg outcome "$outcome" --arg backend "$backend" --arg run_id "$run_id" \
      --arg error "$error" --arg host "$(hostname)" \
      --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
      --argjson exit_code "$exit_code" \
      '{schema: 1, outcome: $outcome, backend: $backend, run_id: $run_id,
        error: $error, exit_code: $exit_code, host: $host, at: $at}')"
}

# curl speaks SMTP, so email needs no dependency the image does not already
# have. NOTIFY_SMTP_URL carries any credentials; they are stripped from the
# URL handed to --url and passed through --user instead, so the endpoint can
# be logged safely.
_notify_smtp() {
  local subject="$1" body="$2"
  local url="$NOTIFY_SMTP_URL" creds="" host_part msg

  host_part="${url#*://}"
  if [[ "$host_part" == *@* ]]; then
    creds="${host_part%%@*}"
    host_part="${host_part#*@}"
  fi
  url="${NOTIFY_SMTP_URL%%://*}://${host_part}"

  msg="$(mktemp)" || {
    log_warn "Notification via smtp failed: no temporary file"
    return 0
  }
  {
    printf 'From: %s\n' "$NOTIFY_SMTP_FROM"
    printf 'To: %s\n' "$NOTIFY_SMTP_TO"
    printf 'Subject: %s\n' "$subject"
    printf 'Date: %s\n' "$(date -uR)"
    printf 'Content-Type: text/plain; charset=utf-8\n\n'
    printf '%s\n' "$body"
  } >"$msg"

  local args=(--ssl-reqd --max-time "$NOTIFY_TIMEOUT" --url "$url"
    --mail-from "$NOTIFY_SMTP_FROM" --upload-file "$msg")
  local addr
  for addr in ${NOTIFY_SMTP_TO//,/ }; do
    args+=(--mail-rcpt "$addr")
  done
  [[ -n "$creds" ]] && args+=(--user "$creds")

  curl -fsS "${args[@]}" >/dev/null 2>&1 ||
    log_warn "Notification via smtp failed"
  rm -f -- "$msg"
}

# notify_run OUTCOME BACKEND RUN_ID ERROR EXIT_CODE PREVIOUS_OUTCOME
# Always returns 0. A backup that worked stays worked even if every channel is
# unreachable.
notify_run() {
  local outcome="$1" backend="$2" run_id="$3" error="$4" exit_code="$5"
  local previous="${6:-none}"
  local channels label subject text channel

  notify_should_send "$outcome" "$previous" || return 0

  channels="$(notify_channels)"
  [[ -n "$channels" ]] || return 0

  label="$outcome"
  [[ "$outcome" == "success" && "$previous" == "failure" ]] && label=recovered

  subject="$(_notify_subject "$label" "$backend")"
  text="$(_notify_text "$label" "$backend" "$run_id" "$error" "$exit_code")"

  while IFS= read -r channel; do
    [[ -n "$channel" ]] || continue
    # Each channel in its own subshell: one blowing up must not take the rest
    # of the notifications, or the run, with it.
    (
      case "$channel" in
        slack) _notify_slack "$text" ;;
        google_chat) _notify_google_chat "$text" ;;
        discord) _notify_discord "$text" ;;
        telegram) _notify_telegram "$text" ;;
        webhook) _notify_webhook "$label" "$backend" "$run_id" "$error" "$exit_code" ;;
        smtp) _notify_smtp "$subject" "$text" ;;
      esac
    ) || log_warn "Notification via ${channel} raised an error"
  done <<<"$channels"

  return 0
}
