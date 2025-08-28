#!/usr/bin/env bash
set -euo pipefail

ERROR_MESSAGE="scrapemate exited"
LOGFILE=/app/webdata/scraper.log
WATCHDOG_LOG=/app/webdata/watchdog.log
TIMEOUT=60   # seconds of "same log" before exit
EXIT_TIMEOUT=300  # seconds with same exit message before killing container

mkdir -p /app/webdata
: > "$LOGFILE"
: > "$WATCHDOG_LOG"

log() {
  printf '%s WATCHDOG %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$WATCHDOG_LOG"
  # Keep only the last 100 lines
  tmpfile=$(mktemp)
  tail -n 100 "$WATCHDOG_LOG" > "$tmpfile" && cat "$tmpfile" > "$WATCHDOG_LOG"
  rm -f "$tmpfile"
}

log "start — container and watchdog initialized"

# Start scraper and append logs
stdbuf -oL -eL google-maps-scraper "$@" 2>&1 | tee -a "$LOGFILE" &
PID=$!

# Track "same log" stability
last_line=""
last_change_time=$(date +%s)  # when last_line last CHANGED (content-wise)

# Read tail lines in the SAME shell (no subshell variable loss)
exec 3< <(tail -n0 -F "$LOGFILE")

trim_log() {
  tmpfile=$(mktemp)
  tail -n 250 "$LOGFILE" > "$tmpfile" && cat "$tmpfile" > "$LOGFILE"
  rm -f "$tmpfile"
}

while :; do
  # Wait up to TIMEOUT seconds for a new line; if none, we just check stability.
  if IFS= read -r -t "$TIMEOUT" -u 3 line; then
    # Ignore empty/whitespace-only lines
    [[ -z ${line//[[:space:]]/} ]] && continue

    # If content changed, update the "change clock"
    if [[ "$line" != "$last_line" ]]; then
      last_line="$line"
      last_change_time=$(date +%s)
    fi
  fi

  # "Idle" here means: same content for N seconds (or no new lines)
  now=$(date +%s)
  stable=$(( now - last_change_time ))

  # Housekeeping
  trim_log

  if (( stable >= TIMEOUT )); then
    if grep -q "$ERROR_MESSAGE" <<<"$last_line" || (( stable >= EXIT_TIMEOUT )); then
      log "stable=${stable}s with same last_line (exit msg) → restarting..."
      kill -TERM "$PID" 2>/dev/null || true
      exec 3<&-   # close fd
      exit 1      # exit watchdog immediately → container stops/restarts
      break
    else
      log "stable=${stable}s but last_line does not match exit message (ok)"
    fi
  fi
done

log "watchdog stopped"

# Cleanup
exec 3<&-
wait "$PID" || true
exit 1   # non-zero exit forces restart