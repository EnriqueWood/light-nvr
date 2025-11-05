#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/stream_config.sh"

STREAM_ID=$1
PROCESS_PID=$2
SOCKET_PATH="/tmp/mpvsocket-$STREAM_ID"
RELOAD_ATTEMPTS=5
MAX_INNER_ATTEMPTS=5
ATTEMPT_SLEEP_SECONDS=2
INNER_SLEEP_SECONDS=2

source "$SCRIPT_DIR/config.env"

if ! parse_stream_config; then
  echo "ERROR: Failed to parse stream configuration" >&2
  exit 1
fi

STREAM_NAME=$(get_name_by_index "$STREAM_ID")

if [ -z "$STREAM_NAME" ]; then
  echo "ERROR: Could not find stream at index $STREAM_ID" >&2
  exit 1
fi

init_logging "watchdog-$STREAM_NAME" "pid: $PROCESS_PID"

pid_exists() {
  ps -p "$PROCESS_PID" > /dev/null 2>&1
}

kill_process() {
  log_info "Attempting graceful termination of process $PROCESS_PID"
  kill -TERM "$PROCESS_PID" 2>/dev/null

  for i in {1..5}; do
    if ! pid_exists; then
      log_info "Process terminated gracefully after ${i}s"
      return 0
    fi
    log_debug "Waiting for graceful termination (attempt $i/5)"
    sleep 1
  done

  log_warning "Process did not terminate gracefully after 5s. Force killing."
  kill -9 "$PROCESS_PID" 2>/dev/null

  sleep 1
  if ! pid_exists; then
    log_info "Process force-killed successfully"
  else
    log_error "Failed to kill process even with SIGKILL"
  fi
  return 1
}

# Give mpv 90s to start up and create its IPC socket
log_info "Starting socket initialization check (grace period: 90 seconds, socket: $SOCKET_PATH)"
MAX_SOCKET_WAIT=90
SOCKET_WAIT=0
while [ $SOCKET_WAIT -lt $MAX_SOCKET_WAIT ]; do
  if [ -S "$SOCKET_PATH" ]; then
    log_debug "Socket file exists, testing responsiveness..."
    TEST_RESULT=$(echo '{"command": ["get_property", "path"]}' | socat -t 2 - "$SOCKET_PATH" 2>/dev/null)
    if [ -n "$TEST_RESULT" ]; then
      log_info "Socket is ready and responsive after $SOCKET_WAIT seconds"
      SANITIZED_RESPONSE=$(echo "$TEST_RESULT" | sed -E 's|(rtsp://)[^:]+:[^@]+@|\1****:****@|g')
      log_debug "Socket test response: $SANITIZED_RESPONSE"
      break
    else
      log_debug "Socket file exists but not yet responsive (attempt $SOCKET_WAIT/$MAX_SOCKET_WAIT)"
    fi
  else
    if [ $((SOCKET_WAIT % 10)) -eq 0 ] && [ $SOCKET_WAIT -gt 0 ]; then
      log_info "Still waiting for socket creation... ($SOCKET_WAIT/$MAX_SOCKET_WAIT seconds elapsed)"
    fi
  fi
  SOCKET_WAIT=$((SOCKET_WAIT + 1))
  sleep 1
done

if [ $SOCKET_WAIT -ge $MAX_SOCKET_WAIT ]; then
  log_error "Socket did not become ready within $MAX_SOCKET_WAIT seconds"
  log_error "Stream initialization failed. Process will be terminated to prevent unsupervised execution"
  if pid_exists; then
    kill_process
    log_info "Watchdog exiting after killing unresponsive process"
  else
    log_warning "Process already terminated during socket wait. Watchdog exiting"
  fi
  exit 1
fi

log_info "Starting stream health monitoring for '$STREAM_NAME' (check interval: 3s, reload attempts: $RELOAD_ATTEMPTS, inner retries: $MAX_INNER_ATTEMPTS)"

HEALTH_CHECK_COUNT=0

while true; do
  HEALTH_CHECK_COUNT=$((HEALTH_CHECK_COUNT + 1))

  if [ ! -S "$SOCKET_PATH" ]; then
    log_error "Socket $SOCKET_PATH disappeared during monitoring (health check #$HEALTH_CHECK_COUNT)"
    log_error "This indicates mpv crashed or closed the IPC socket. Process will be killed"
    kill_process
    log_info "Watchdog exiting due to missing socket"
    exit 1
  fi

  if ! pid_exists; then
    log_warning "Process $PROCESS_PID no longer exists (health check #$HEALTH_CHECK_COUNT)"
    log_info "Stream terminated externally or crashed. Watchdog exiting"
    exit 1
  fi
  log_debug "[health-check #$HEALTH_CHECK_COUNT] Querying initial time position..."
  inner_attempt=0
  while [ $inner_attempt -lt $MAX_INNER_ATTEMPTS ]; do
    OLD_TIME_JSON=$(echo '{"command": ["get_property", "time-pos"]}' | socat - "$SOCKET_PATH" 2>&1)
    OLD_ERROR=$(echo "$OLD_TIME_JSON" | jq -r '.error' 2>/dev/null)
    if [ "$OLD_ERROR" = "success" ]; then
      break
    fi
    inner_attempt=$((inner_attempt + 1))
    if [ $inner_attempt -lt $MAX_INNER_ATTEMPTS ]; then
      log_warning "[health-check #$HEALTH_CHECK_COUNT] Failed to get time-pos (attempt $inner_attempt/$MAX_INNER_ATTEMPTS), retrying in ${INNER_SLEEP_SECONDS}s. Error: $OLD_ERROR"
      sleep $INNER_SLEEP_SECONDS
    fi
  done

  if [ "$OLD_ERROR" != "success" ]; then
    log_error "[health-check #$HEALTH_CHECK_COUNT] Failed to retrieve time position after $MAX_INNER_ATTEMPTS retries"
    log_error "Last error: $OLD_ERROR. Socket is unresponsive. Process will be killed"
    kill_process
    log_info "Watchdog exiting due to unresponsive socket"
    exit 1
  fi

  OLD_TIME=$(echo "$OLD_TIME_JSON" | jq '.data')
  if [ "$OLD_TIME" = "null" ]; then
    log_error "[health-check #$HEALTH_CHECK_COUNT] Received null time position after retries"
    log_error "Stream may not be playing. Process will be killed"
    kill_process
    log_info "Watchdog exiting due to null time position"
    exit 1
  fi

  log_debug "[health-check #$HEALTH_CHECK_COUNT] Initial time position: $OLD_TIME seconds"

  sleep 3

  if [ ! -S "$SOCKET_PATH" ]; then
    log_error "Socket $SOCKET_PATH disappeared between time checks (health check #$HEALTH_CHECK_COUNT)"
    kill_process
    log_info "Watchdog exiting due to missing socket"
    exit 1
  fi

  log_debug "[health-check #$HEALTH_CHECK_COUNT] Querying new time position (3s later)..."
  inner_attempt=0
  while [ $inner_attempt -lt $MAX_INNER_ATTEMPTS ]; do
    NEW_TIME_JSON=$(echo '{"command": ["get_property", "time-pos"]}' | socat - "$SOCKET_PATH" 2>&1)
    NEW_ERROR=$(echo "$NEW_TIME_JSON" | jq -r '.error' 2>/dev/null)
    if [ "$NEW_ERROR" = "success" ]; then
      break
    fi
    inner_attempt=$((inner_attempt + 1))
    if [ $inner_attempt -lt $MAX_INNER_ATTEMPTS ]; then
      log_warning "[health-check #$HEALTH_CHECK_COUNT] Failed to get new time-pos (attempt $inner_attempt/$MAX_INNER_ATTEMPTS), retrying in ${INNER_SLEEP_SECONDS}s. Error: $NEW_ERROR"
      sleep $INNER_SLEEP_SECONDS
    fi
  done

  if [ "$NEW_ERROR" != "success" ]; then
    log_error "[health-check #$HEALTH_CHECK_COUNT] Failed to retrieve new time position after $MAX_INNER_ATTEMPTS retries"
    log_error "Last error: $NEW_ERROR. Socket became unresponsive. Process will be killed"
    kill_process
    log_info "Watchdog exiting due to unresponsive socket"
    exit 1
  fi

  NEW_TIME=$(echo "$NEW_TIME_JSON" | jq '.data')
  if [ "$NEW_TIME" = "null" ]; then
    log_error "[health-check #$HEALTH_CHECK_COUNT] Received null new time position after retries"
    log_error "Stream stopped playing. Process will be killed"
    kill_process
    log_info "Watchdog exiting due to null time position"
    exit 1
  fi

  log_debug "[health-check #$HEALTH_CHECK_COUNT] New time position: $NEW_TIME seconds"

  if [ "$OLD_TIME" = "$NEW_TIME" ]; then
    log_warning "[health-check #$HEALTH_CHECK_COUNT] Stream '$STREAM_NAME' appears frozen (time-pos did not advance: stuck at $OLD_TIME seconds)"
    log_info "Initiating reload sequence to recover stream '$STREAM_NAME'..."

    log_info "[reload] Retrieving stream path from mpv..."
    FILE_JSON=$(echo '{"command": ["get_property", "path"]}' | socat - "$SOCKET_PATH" 2>&1)
    FILE_ERROR=$(echo "$FILE_JSON" | jq -r '.error' 2>/dev/null)
    if [ "$FILE_ERROR" != "success" ]; then
      log_error "[reload] Failed to retrieve stream path from mpv. Error: $FILE_ERROR"
      log_error "Cannot reload without stream path. Process will be killed"
      kill_process
      log_info "Watchdog exiting due to reload failure"
      exit 1
    fi

    FILE_PATH=$(echo "$FILE_JSON" | jq -r '.data')
    if [ "$FILE_PATH" = "null" ] || [ -z "$FILE_PATH" ]; then
      log_error "[reload] Retrieved empty or null stream path from mpv"
      log_error "Cannot reload without valid stream path. Process will be killed"
      kill_process
      log_info "Watchdog exiting due to invalid stream path"
      exit 1
    fi

    log_info "[reload] Stream path retrieved for '$STREAM_NAME'"
    log_info "[reload] Sending loadfile command to mpv..."
    RELOAD_JSON=$(echo '{"command": ["loadfile", "'"$FILE_PATH"'", "replace"]}' | socat - "$SOCKET_PATH" 2>&1)
    RELOAD_ERROR=$(echo "$RELOAD_JSON" | jq -r '.error' 2>/dev/null)
    if [ "$RELOAD_ERROR" != "success" ]; then
      log_error " [reload] Reload command rejected by mpv. Error: $RELOAD_ERROR"
      log_error " Stream cannot be recovered. Process will be killed."
      kill_process
      log_info " Watchdog exiting due to failed reload command"
      exit 1
    fi

    log_info " [reload] Reload command accepted. Waiting 3 seconds for stream restart..."
    sleep 3

    log_info " [reload] Starting reload verification (max $RELOAD_ATTEMPTS attempts)..."
    SUCCESS=0
    for i in $(seq 1 $RELOAD_ATTEMPTS); do
      log_info " [reload] Verification attempt $i/$RELOAD_ATTEMPTS (waiting ${ATTEMPT_SLEEP_SECONDS}s before check)..."
      sleep $ATTEMPT_SLEEP_SECONDS

      inner_attempt=0
      while [ $inner_attempt -lt $MAX_INNER_ATTEMPTS ]; do
        CHECK_JSON=$(echo '{"command": ["get_property", "time-pos"]}' | socat - "$SOCKET_PATH" 2>&1)
        CHECK_ERROR=$(echo "$CHECK_JSON" | jq -r '.error' 2>/dev/null)
        if [ "$CHECK_ERROR" = "success" ]; then
          break
        fi
        inner_attempt=$((inner_attempt + 1))
        if [ $inner_attempt -lt $MAX_INNER_ATTEMPTS ]; then
          log_warning " [reload] Socket query failed (sub-attempt $inner_attempt/$MAX_INNER_ATTEMPTS). Error: $CHECK_ERROR. Retrying in ${INNER_SLEEP_SECONDS}s..."
          sleep $INNER_SLEEP_SECONDS
        fi
      done

      if [ "$CHECK_ERROR" != "success" ]; then
        log_warning " [reload] Could not query time-pos on verification attempt $i/$RELOAD_ATTEMPTS after $MAX_INNER_ATTEMPTS retries. Error: $CHECK_ERROR"
        continue
      fi

      CHECK_TIME=$(echo "$CHECK_JSON" | jq '.data')
      if [ "$CHECK_TIME" = "null" ]; then
        log_warning " [reload] Received null time-pos on verification attempt $i/$RELOAD_ATTEMPTS"
        continue
      fi

      if [ "$OLD_TIME" != "$CHECK_TIME" ]; then
        log_info " SUCCESS: [reload] Stream recovered! Playback time changed from $OLD_TIME to $CHECK_TIME seconds (verification attempt $i/$RELOAD_ATTEMPTS)"
        SUCCESS=1
        break
      else
        log_warning " [reload] Verification attempt $i/$RELOAD_ATTEMPTS: playback time still stuck at $CHECK_TIME seconds"
      fi
    done

    if [ $SUCCESS -ne 1 ]; then
      log_error " [reload] Stream '$STREAM_NAME' recovery failed. Playback time did not advance after $RELOAD_ATTEMPTS verification attempts."
      log_error " Stream is unrecoverable. Process will be killed."
      kill_process
      log_info " Watchdog exiting due to failed stream recovery"
      exit 1
    fi

    log_info " [reload] Reload sequence completed successfully for '$STREAM_NAME'. Resuming normal health monitoring."
    continue
  fi

  log_info " [health-check #$HEALTH_CHECK_COUNT] Stream '$STREAM_NAME' is healthy (playback advanced from $OLD_TIME to $NEW_TIME seconds)"
  sleep 3
done
