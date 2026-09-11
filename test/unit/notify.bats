#!/usr/bin/env bats
#
# Notification dispatch. A stubbed curl records every request, so these assert
# what would go on the wire without one leaving the machine.

setup() {
  set -euo pipefail
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  source "$REPO_ROOT/lib/log.sh"
  source "$REPO_ROOT/lib/env.sh"
  source "$REPO_ROOT/lib/notify.sh"

  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  CURL_CALLS="$BATS_TEST_TMPDIR/curl-calls"
  mkdir -p "$STUB_BIN"
  : >"$CURL_CALLS"
  # One line per invocation: payloads contain newlines, so recording "$*"
  # verbatim would make a line count meaningless.
  cat >"$STUB_BIN/curl" <<STUB
#!/usr/bin/env bash
args="\$*"
printf '%s\n' "\${args//\$'\\n'/ }" >>"$CURL_CALLS"
exit \${STUB_CURL_EXIT:-0}
STUB
  chmod +x "$STUB_BIN/curl"
  PATH="$STUB_BIN:$PATH"

  # Nothing configured unless a test says so.
  unset NOTIFY_SLACK_WEBHOOK_URL NOTIFY_GOOGLE_CHAT_WEBHOOK_URL \
    NOTIFY_DISCORD_WEBHOOK_URL NOTIFY_TELEGRAM_BOT_TOKEN \
    NOTIFY_TELEGRAM_CHAT_ID NOTIFY_WEBHOOK_URL NOTIFY_SMTP_URL 2>/dev/null || true
  NOTIFY_ON=failure
}

calls() { cat "$CURL_CALLS"; }

# --- when to send ------------------------------------------------------------

@test "never sends nothing at all" {
  NOTIFY_ON=never run notify_should_send failure none
  [ "$status" -ne 0 ]
}

@test "always sends on success" {
  NOTIFY_ON=always run notify_should_send success success
  [ "$status" -eq 0 ]
}

@test "failure sends on every failure" {
  NOTIFY_ON=failure run notify_should_send failure failure
  [ "$status" -eq 0 ]
}

@test "failure stays quiet on an unremarkable success" {
  NOTIFY_ON=failure run notify_should_send success success
  [ "$status" -ne 0 ]
}

@test "failure announces recovery" {
  # The first success after a failure is worth a message; without it you never
  # learn the problem went away.
  NOTIFY_ON=failure run notify_should_send success failure
  [ "$status" -eq 0 ]
}

@test "change reports the first failure but not the next one" {
  NOTIFY_ON=change run notify_should_send failure success
  [ "$status" -eq 0 ]

  NOTIFY_ON=change run notify_should_send failure failure
  [ "$status" -ne 0 ]
}

@test "an unknown NOTIFY_ON is rejected" {
  NOTIFY_ON=sometimes run notify_should_send failure none
  [ "$status" -gt 1 ]
}

# --- channel detection -------------------------------------------------------

@test "no configuration means no channels" {
  run notify_channels
  [ "$output" = "" ]
}

@test "each configured channel is picked up, several at once" {
  NOTIFY_SLACK_WEBHOOK_URL=https://hooks.example/s \
    NOTIFY_WEBHOOK_URL=https://hook.example/w \
    NOTIFY_TELEGRAM_BOT_TOKEN=t NOTIFY_TELEGRAM_CHAT_ID=1 \
    run notify_channels

  [[ "$output" == *slack* ]]
  [[ "$output" == *webhook* ]]
  [[ "$output" == *telegram* ]]
}

@test "telegram needs both token and chat id" {
  NOTIFY_TELEGRAM_BOT_TOKEN=t run notify_channels
  [[ "$output" != *telegram* ]]
}

# --- what goes on the wire ---------------------------------------------------

@test "slack posts JSON to its webhook" {
  NOTIFY_SLACK_WEBHOOK_URL=https://hooks.example/s \
    notify_run failure postgresql 20260101_000000 'Access Denied' 4 success

  run calls
  [[ "$output" == *"https://hooks.example/s"* ]]
  [[ "$output" == *"application/json"* ]]
}

@test "telegram posts to the configurable api base" {
  # Configurable so this can be tested at all.
  NOTIFY_TELEGRAM_BOT_TOKEN=abc NOTIFY_TELEGRAM_CHAT_ID=42 \
    NOTIFY_TELEGRAM_API_BASE=https://tg.test \
    notify_run failure etcd 20260101_000000 'boom' 3 success

  run calls
  [[ "$output" == *"https://tg.test/botabc/sendMessage"* ]]
}

@test "the generic webhook carries structured fields, not prose" {
  NOTIFY_WEBHOOK_URL=https://hook.example/w \
    notify_run failure mongodb 20260101_000000 'boom' 3 success

  run calls
  [[ "$output" == *'"backend":"mongodb"'* ]]
  [[ "$output" == *'"outcome":"failure"'* ]]
  [[ "$output" == *'"exit_code":3'* ]]
}

@test "email goes over smtp with an envelope" {
  NOTIFY_SMTP_URL=smtps://user:pw@smtp.example:465 \
    NOTIFY_SMTP_FROM=backup@example.com NOTIFY_SMTP_TO=ops@example.com \
    notify_run failure vault 20260101_000000 'boom' 3 success

  run calls
  [[ "$output" == *"smtps://smtp.example:465"* ]]
  [[ "$output" == *"--mail-from backup@example.com"* ]]
  [[ "$output" == *"--mail-rcpt ops@example.com"* ]]
}

@test "every configured channel is attempted" {
  NOTIFY_SLACK_WEBHOOK_URL=https://hooks.example/s \
    NOTIFY_DISCORD_WEBHOOK_URL=https://discord.example/d \
    NOTIFY_GOOGLE_CHAT_WEBHOOK_URL=https://chat.example/g \
    notify_run failure etcd 20260101_000000 'boom' 3 success

  [ "$(calls | wc -l)" -eq 3 ]
}

# --- failure isolation -------------------------------------------------------

@test "a channel that fails does not stop the others" {
  STUB_CURL_EXIT=7 NOTIFY_SLACK_WEBHOOK_URL=https://hooks.example/s \
    NOTIFY_DISCORD_WEBHOOK_URL=https://discord.example/d \
    run notify_run failure etcd 20260101_000000 'boom' 3 success

  [ "$(calls | wc -l)" -eq 2 ]
}

@test "notification failure never changes the run's outcome" {
  STUB_CURL_EXIT=7 NOTIFY_SLACK_WEBHOOK_URL=https://hooks.example/s \
    run notify_run failure etcd 20260101_000000 'boom' 3 success

  [ "$status" -eq 0 ]
}

@test "secrets never reach the log" {
  # Exported, or the stub — a separate process — never sees it, curl
  # "succeeds", no warning is logged and this asserts nothing.
  export STUB_CURL_EXIT=7
  NOTIFY_SLACK_WEBHOOK_URL=https://hooks.example/T00/B11/sekrit \
    run notify_run failure etcd 20260101_000000 'boom' 3 success

  [[ "$output" == *"Notification via slack failed"* ]]

  [[ "$output" != *"sekrit"* ]]
}

@test "a curl timeout is always set" {
  # An unreachable notifier must not hold the container open.
  NOTIFY_WEBHOOK_URL=https://hook.example/w \
    notify_run failure etcd 20260101_000000 'boom' 3 success

  run calls
  [[ "$output" == *"--max-time"* ]]
}

# --- long errors must not lose the notification ------------------------------
# Telegram rejects a message over 4096 characters with 400, and Discord over
# 2000. A verbose dump failure is exactly when the message matters most, so
# the chat text is capped while machine-readable channels keep the full text.

long_error() { head -c 6000 /dev/zero | tr '\0' 'E'; }

@test "a long error is truncated in the chat message" {
  NOTIFY_TELEGRAM_BOT_TOKEN=abc NOTIFY_TELEGRAM_CHAT_ID=42 \
    NOTIFY_TELEGRAM_API_BASE=https://tg.test \
    notify_run failure etcd 20260101_000000 "$(long_error)" 3 success

  run calls
  [ "${#output}" -lt 4096 ]
  [[ "$output" == *"truncated"* ]]
}

@test "discord stays inside its smaller limit too" {
  NOTIFY_DISCORD_WEBHOOK_URL=https://discord.example/d \
    notify_run failure etcd 20260101_000000 "$(long_error)" 3 success

  run calls
  [ "${#output}" -lt 2000 ]
}

@test "the webhook keeps the full error for machines to read" {
  NOTIFY_WEBHOOK_URL=https://hook.example/w \
    notify_run failure etcd 20260101_000000 "$(long_error)" 3 success

  run calls
  [ "${#output}" -gt 5000 ]
}

@test "a short error is left exactly as it is" {
  NOTIFY_TELEGRAM_BOT_TOKEN=abc NOTIFY_TELEGRAM_CHAT_ID=42 \
    NOTIFY_TELEGRAM_API_BASE=https://tg.test \
    notify_run failure etcd 20260101_000000 'disk full' 3 success

  run calls
  [[ "$output" == *"disk full"* ]]
  [[ "$output" != *"truncated"* ]]
}
