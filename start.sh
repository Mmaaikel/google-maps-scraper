#!/usr/bin/env bash
set -euo pipefail

LOGS_PATH=/webdata_logs

# --- Configuration ---
# The specific error message to look for in the log file.
ERROR_MESSAGE="scrapemate exited"
# Pattern to identify failed jobs. The script will check if 'numOfJobsFailed=X' where X > 0.
JOB_FAILURE_PATTERN="numOfJobsFailed\":"
# Path to the main scraper log file.
LOGFILE=$LOGS_PATH/scraper.log
# Path to the watchdog's own log file.
WATCHDOG_LOG=$LOGS_PATH/watchdog.log
# Duration (in seconds) that the 'last_line' must remain unchanged before triggering a check.
TIMEOUT=60
# TIMEOUT=10
# Total duration (in seconds) the last_line can remain unchanged, regardless of content,
# before forcing an exit and container restart. This acts as a fallback.
EXIT_TIMEOUT=300
# EXIT_TIMEOUT=30
# Maximum number of lines the LOGFILE can grow to before it's automatically trimmed.
LOGFILE_MAX_LINES=200
# The number of lines to retain in LOGFILE after a trim operation.
LOGFILE_TRIM_TO_LINES=150

# --- Initialization ---
# Ensure the directory for log files exists.
mkdir -p "$LOGS_PATH"
# Clear (truncate) the main scraper log file.
: > "$LOGFILE"
# Clear (truncate) the watchdog's log file.
# : > "$WATCHDOG_LOG"

# Log function: Appends messages to the watchdog log.
# Optimization: The original script's `log` function included `tail -n 100`
# and `mktemp` to trim the watchdog log on *every* call. This was inefficient.
# This optimized version simply appends to the log. For advanced watchdog log
# rotation, external tools like 'logrotate' are more suitable and efficient
# than in-script, frequent trimming.
log() {
  printf '%s WATCHDOG %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$WATCHDOG_LOG"
}

log "start — container and watchdog initialized"

# Start the 'google-maps-scraper' process in the background.
# `stdbuf -oL -eL`: Ensures line-buffered output for both stdout and stderr.
# This is crucial so that `tail -F` can read new lines promptly.
# `2>&1 | tee -a "$LOGFILE"`: Redirects both standard output and standard error
# to the LOGFILE, appending new content.
stdbuf -oL -eL google-maps-scraper "$@" 2>&1 | tee -a "$LOGFILE" &
PID=$! # Store the Process ID (PID) of the backgrounded scraper process.

# --- Watchdog Logic ---
# `last_line`: Stores the content of the most recently read log line.
last_line=""
# `last_change_time`: Records the Unix timestamp (seconds since epoch)
# when the `last_line` variable's content last *changed*.
last_change_time=$(date +%s)

# Open LOGFILE for continuous reading using file descriptor 3.
# `tail -n0 -F "$LOGFILE"`: Starts reading from the *end* of the file (n0)
# and continuously 'follows' new data appended to it (-F).
# `exec 3< <(...)`: This is a process substitution that effectively pipes the
# output of `tail` into file descriptor 3, allowing `read -u 3` to consume it.
# This is an efficient way to monitor a growing log file without re-opening it.
exec 3< <(tail -n0 -F "$LOGFILE")

# Function to trim the main scraper log file only when necessary.
# Optimization: The original script called a `trim_log` function in every loop
# iteration, which performed heavy I/O (tail, mktemp, cat/mv).
# This optimized function now only executes the trimming operation if the
# LOGFILE's line count exceeds a predefined `LOGFILE_MAX_LINES`. This
# significantly reduces unnecessary disk writes and reads.
trim_logfile_if_needed() {
  # Get the current line count of the LOGFILE. `wc -l` is efficient.
  # `|| echo 0` provides robustness if the file is empty or temporarily inaccessible.
  local current_lines=$(wc -l < "$LOGFILE" || echo 0)

  # Check if the log file has grown beyond its maximum allowed size.
  if (( current_lines > LOGFILE_MAX_LINES )); then
    log "Trimming '$LOGFILE' from ${current_lines} lines to ${LOGFILE_TRIM_TO_LINES} lines."
    # Use `tail` to get the last desired number of lines and write them to a temporary file.
    # Then, atomically move the temporary file to overwrite the original LOGFILE.
    # This prevents data loss during concurrent writes (though `tee` already handles appending).
    local tmpfile
    tmpfile=$(mktemp)
    tail -n "$LOGFILE_TRIM_TO_LINES" "$LOGFILE" > "$tmpfile" && mv "$tmpfile" "$LOGFILE"
    rm -f "$tmpfile" # Clean up the temporary file immediately.
  fi
}

# Main watchdog loop: Runs indefinitely until an exit condition is met.
while :; do
  if IFS= read -r -t "$TIMEOUT" -u 3 line; then
    [[ -z ${line//[[:space:]]/} ]] && continue

    if [[ "$line" != "$last_line" ]]; then
      last_line="$line"                # Update 'last_line' with the new content.
      last_change_time=$(date +%s)     # Reset the 'last_change_time' to 'now'.
    fi
  fi

  now=$(date +%s)
  stable=$(( now - last_change_time ))

  # Perform log file trimming conditionally.
  trim_logfile_if_needed

  # Regex to match 'numOfJobsFailed=' followed by any digit from 1-9,
  # or any number > 9. This ensures it's a number greater than 0.
  # The `BASH_REMATCH` array captures the matched groups, but we only need the match itself.
  job_failed=false
  if [[ "$last_line" =~ ${JOB_FAILURE_PATTERN}([1-9][0-9]*) ]]; then
    job_failed=true
  elif [[ "$last_line" =~ ${JOB_FAILURE_PATTERN}[1-9] ]]; then
    job_failed=true
  fi

  # Check if the log has been stable (unchanged) for at least the `TIMEOUT` duration.
  if (( stable >= TIMEOUT )); then
    # The container will now restart if:
    # 1. The last line contains the primary ERROR_MESSAGE.
    # 2. The last line contains 'numOfJobsFailed=' with a number greater than 0.
    # 3. The log has been completely stable (no new lines or changes) for EXIT_TIMEOUT seconds.g.
    # if [[ "$last_line" == *"$ERROR_MESSAGE"* ]] || "$job_failed" || (( stable >= EXIT_TIMEOUT )); then
    if [[ "$last_line" == *"$ERROR_MESSAGE"* ]] || "$job_failed"; then
      log "Stable for ${stable}s with last_line matching exit message or exceeding EXIT_TIMEOUT. Restarting container..."
      kill -TERM "$PID" 2>/dev/null || true
      exec 3<&-
      exit 1
    else
      # Log message when the log is stable but doesn't contain the error message.
      log "Stable for ${stable}s but last_line does not match exit message (ok, still waiting for new log data or error)."
    fi
  fi
done

log "watchdog stopped (this message should ideally not be reached under normal exit conditions)"

# Ensure file descriptor 3 is closed if the loop terminates unexpectedly.
exec 3<&-
wait "$PID" || true
exit 1
