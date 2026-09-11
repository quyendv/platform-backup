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

_notify_status_word() {
  case "$1" in
    failure) printf 'FAILED' ;;
    recovered) printf 'RECOVERED' ;;
    *) printf 'SUCCEEDED' ;;
  esac
}

# Red or green, so a chat history can be scanned without reading. Recovery is
# green — it is good news — and the word carries the distinction.
_notify_status_icon() {
  case "$1" in
    failure) printf '\xf0\x9f\x94\xb4' ;;
    *) printf '\xf0\x9f\x9f\xa2' ;;
  esac
}

# "55 sec" and "62 min 5 sec" rather than raw seconds.
_notify_duration() {
  local s="${1:-0}"
  [[ "$s" =~ ^[0-9]+$ ]] || s=0
  if ((s < 60)); then
    printf '%d sec' "$s"
  else
    printf '%d min %d sec' $((s / 60)) $((s % 60))
  fi
}

# Email subject: scannable in an inbox list, and plain so no client mangles it.
_notify_subject() {
  local outcome="$1" backend="$2"
  printf '[%s] %s backup on %s' \
    "$(_notify_status_word "$outcome")" "$backend" "$(hostname)"
}

_notify_truncate() {
  local text="$1" limit="$2"
  if ((${#text} > limit)); then
    printf '%s… (truncated, %d characters)' "${text:0:limit}" "${#text}"
  else
    printf '%s' "$text"
  fi
}

# Telegram answers 400 "can't parse entities" on a stray < or &, so HTML mode
# means escaping is not optional.
# sed, not ${var//}: since bash 5.2 an unescaped & in the replacement means
# "the text that matched", so ${t//</&lt;} produces "<lt;" rather than "&lt;"
# — and Telegram then rejects the message it cannot parse.
_notify_escape_html() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# The body is rendered from _N_* rather than a dozen positional arguments.
# notify_run sets them; every renderer reads the same set.
#
# _notify_body FLAVOUR   plain | html | markdown
#   plain     email, and anything that shows text verbatim
#   html      Telegram, far easier to escape correctly than MarkdownV2
#   markdown  Slack, Discord and Google Chat, which all fence with backticks
#
# Layout follows the shape people already read in build notifications: an
# icon-and-status header, a blank line, then one aligned field per line.
_notify_body() {
  local flavour="$1" header error fence='```'

  header="$(printf '%s %s \xe2\x80\xba %s \xe2\x80\x94 %s' \
    "$(_notify_status_icon "$_N_OUTCOME")" "$(hostname)" \
    "$_N_BACKEND" "$(_notify_status_word "$_N_OUTCOME")")"

  case "$flavour" in
    html) header="<b>$(_notify_escape_html "$header")</b>" ;;
    markdown) header="*${header}*" ;;
  esac

  printf '%s\n\n' "$header"
  # Padded to the longest key so the colons line up.
  printf '%-8s: %s UTC\n' 'Run' "${_N_RUN_ID:-n/a}"
  printf '%-8s: %s\n' 'Target' "${_N_TARGET:-unknown}"
  printf '%-8s: %s' 'Duration' "$(_notify_duration "${_N_DURATION:-0}")"

  [[ "$_N_OUTCOME" == "failure" ]] || return 0

  error="$(_notify_truncate "${_N_ERROR:-unknown}" "$NOTIFY_MAX_ERROR_CHARS")"
  printf '\n%-8s: %s\n' 'Exit' "${_N_EXIT:-1}"
  printf '%-8s:\n' 'Error'
  case "$flavour" in
    html) printf '<pre>%s</pre>' "$(_notify_escape_html "$error")" ;;
    markdown)
      # A fence inside the error would close the block early and leak the
      # rest as prose.
      printf '%s\n%s\n%s' "$fence" "${error//"$fence"/\'\'\'}" "$fence"
      ;;
    *) printf '%s' "$error" | sed 's/^/  /' ;;
  esac
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
    "$(jq -cn --arg t "$(_notify_body markdown)" '{text: $t}')"
}

_notify_google_chat() {
  _notify_post_json google_chat "$NOTIFY_GOOGLE_CHAT_WEBHOOK_URL" \
    "$(jq -cn --arg t "$(_notify_body markdown)" '{text: $t}')"
}

_notify_discord() {
  _notify_post_json discord "$NOTIFY_DISCORD_WEBHOOK_URL" \
    "$(jq -cn --arg t "$(_notify_body markdown)" '{content: $t}')"
}

_notify_telegram() {
  _notify_post_json telegram \
    "${NOTIFY_TELEGRAM_API_BASE}/bot${NOTIFY_TELEGRAM_BOT_TOKEN}/sendMessage" \
    "$(jq -cn --arg c "$NOTIFY_TELEGRAM_CHAT_ID" --arg t "$(_notify_body html)" \
      '{chat_id: $c, text: $t, parse_mode: "HTML"}')"
}

# One host backing several databases to different prefixes needs this to tell
# the messages apart.
_notify_target() {
  if [[ -n "${S3_BUCKET:-}" ]]; then
    printf 's3://%s/%s' "$S3_BUCKET" "${S3_PREFIX:-}"
  else
    printf 'local only (%s)' "${BACKUP_DIR:-/backup}"
  fi
}

# Structured, not prose: this one feeds other software, so it gets the full
# error and no markup.
_notify_webhook() {
  _notify_post_json webhook "$NOTIFY_WEBHOOK_URL" \
    "$(jq -cn \
      --arg outcome "$_N_OUTCOME" --arg backend "$_N_BACKEND" \
      --arg run_id "$_N_RUN_ID" --arg error "$_N_ERROR" \
      --arg target "$_N_TARGET" --arg host "$(hostname)" \
      --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
      --argjson exit_code "${_N_EXIT:-0}" \
      --argjson duration_s "${_N_DURATION:-0}" \
      '{schema: 1, outcome: $outcome, backend: $backend, run_id: $run_id,
        target: $target, error: $error, exit_code: $exit_code,
        duration_s: $duration_s, host: $host, at: $at}')"
}

# curl speaks SMTP, so email needs no dependency the image does not already
# have. NOTIFY_SMTP_URL carries any credentials; they are stripped from the
# URL handed to --url and passed through --user instead, so the endpoint can
# be logged safely.
_notify_smtp() {
  local subject body
  subject="$(_notify_subject "$_N_OUTCOME" "$_N_BACKEND")"
  body="$(_notify_body plain)"
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
# notify_run OUTCOME BACKEND RUN_ID ERROR EXIT_CODE PREVIOUS_OUTCOME [DURATION]
# Always returns 0. A backup that worked stays worked even if every channel is
# unreachable.
notify_run() {
  local outcome="$1" backend="$2" run_id="$3" error="$4" exit_code="$5"
  local previous="${6:-none}" duration="${7:-0}"
  local channels channel

  notify_should_send "$outcome" "$previous" || return 0

  channels="$(notify_channels)"
  [[ -n "$channels" ]] || return 0

  # "recovered" is a presentation state, not an outcome: the run succeeded,
  # and what makes it notable is that the one before it did not.
  _N_OUTCOME="$outcome"
  [[ "$outcome" == "success" && "$previous" == "failure" ]] && _N_OUTCOME=recovered
  _N_BACKEND="$backend"
  _N_RUN_ID="$run_id"
  _N_ERROR="$error"
  _N_EXIT="$exit_code"
  _N_DURATION="$duration"
  _N_TARGET="$(_notify_target)"

  while IFS= read -r channel; do
    [[ -n "$channel" ]] || continue
    # Each channel in its own subshell: one blowing up must not take the rest
    # of the notifications, or the run, with it.
    (
      case "$channel" in
        slack) _notify_slack ;;
        google_chat) _notify_google_chat ;;
        discord) _notify_discord ;;
        telegram) _notify_telegram ;;
        webhook) _notify_webhook ;;
        smtp) _notify_smtp ;;
      esac
    ) || log_warn "Notification via ${channel} raised an error"
  done <<<"$channels"

  return 0
}
