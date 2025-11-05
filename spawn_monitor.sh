#!/bin/bash
STREAM_ID=$1
STREAM_GEOMETRY=$2

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/sanitize.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/stream_config.sh"

source "$SCRIPT_DIR/config.env"

if ! parse_stream_config; then
  echo "ERROR: Failed to parse stream configuration" >&2
  exit 1
fi

STREAM_NAME=$(get_name_by_index "$STREAM_ID")
STREAM_CONNECTION_URI=$(get_url_by_index "$STREAM_ID")

if [ -z "$STREAM_NAME" ]; then
  echo "ERROR: Could not find stream at index $STREAM_ID" >&2
  exit 1
fi

if [ -z "$STREAM_CONNECTION_URI" ]; then
  echo "ERROR: Could not find URL for stream index $STREAM_ID" >&2
  exit 1
fi

init_logging "spawn-$STREAM_NAME"

log_info "STREAM_ID=$STREAM_ID"
log_info "STREAM_NAME=$STREAM_NAME"
log_info "STREAM_CONNECTION_URI=$(sanitize_url "$STREAM_CONNECTION_URI")"
log_info "STREAM_GEOMETRY=$STREAM_GEOMETRY"
log_debug "STREAM_OPTS=$STREAM_OPTS"

SOCKET_PATH="/tmp/mpvsocket-$STREAM_ID"
if [ -S "$SOCKET_PATH" ]; then
  log_warning "Removing stale socket: $SOCKET_PATH"
  if rm -f "$SOCKET_PATH" 2>/dev/null; then
    log_debug "Stale socket removed successfully"
  else
    log_error "Could not remove socket $SOCKET_PATH"
  fi
elif [ -e "$SOCKET_PATH" ]; then
  log_warning "$SOCKET_PATH exists but is not a socket. Removing"
  rm -f "$SOCKET_PATH" 2>/dev/null
fi

log_info "Launching mpv for stream '$STREAM_NAME' (ID: $STREAM_ID)"
log_debug "Starting mpv without URL (will load via IPC socket to hide credentials)"

# shellcheck disable=SC2086
LOGS_FOLDER=$(get_logs_folder)
mpv --idle=yes --geometry="$STREAM_GEOMETRY" --input-ipc-server="/tmp/mpvsocket-$STREAM_ID" $STREAM_OPTS 2> "$LOGS_FOLDER/stream-$STREAM_ID-errors.log" &
STREAM_PID="$!"
log_info "mpv started for stream '$STREAM_NAME' with PID: $STREAM_PID"

# Wait for socket to become available
MAX_SOCKET_WAIT=30
SOCKET_WAIT=0
while [ $SOCKET_WAIT -lt $MAX_SOCKET_WAIT ]; do
  if [ -S "$SOCKET_PATH" ]; then
    log_debug "Socket available after ${SOCKET_WAIT}s, testing responsiveness"
    TEST_RESULT=$(echo '{"command": ["get_property", "idle-active"]}' | socat -t 2 - "$SOCKET_PATH" 2>/dev/null)
    if [ -n "$TEST_RESULT" ]; then
      log_info "Socket is ready and responsive for stream '$STREAM_NAME'"
      break
    fi
  fi
  SOCKET_WAIT=$((SOCKET_WAIT + 1))
  sleep 1
done

if [ $SOCKET_WAIT -ge $MAX_SOCKET_WAIT ]; then
  log_error "Socket did not become ready within $MAX_SOCKET_WAIT seconds for stream '$STREAM_NAME'"
  log_error "Killing mpv process $STREAM_PID"
  kill "$STREAM_PID" 2>/dev/null
  exit 1
fi

# Load the stream URL via IPC socket
log_info "Loading stream URL via IPC socket"
LOAD_RESULT=$(echo '{"command": ["loadfile", "'"$STREAM_CONNECTION_URI"'"]}' | socat -t 5 - "$SOCKET_PATH" 2>&1)
LOAD_ERROR=$(echo "$LOAD_RESULT" | jq -r '.error' 2>/dev/null)

if [ "$LOAD_ERROR" != "success" ]; then
  log_error "Failed to load stream URL via IPC socket. Error: $LOAD_ERROR"
  log_error "Killing mpv process $STREAM_PID"
  kill "$STREAM_PID" 2>/dev/null
  exit 1
fi

log_info "Stream URL loaded successfully for '$STREAM_NAME'"

# Start watchdog for stream health monitoring
log_info "Starting watchdog after 10s delay for stream initialization"
sleep 10
log_debug "Launching watchdog.sh for stream '$STREAM_NAME'"
"$SCRIPT_DIR/watchdog.sh" "$STREAM_ID" "$STREAM_PID" &
WATCHDOG_PID=$!

# Start recording monitor if RECORD_PATH is set
if [ -n "${RECORD_PATH}" ]; then
	log_info "Starting recording monitor for stream '$STREAM_NAME' (path: $RECORD_PATH)"
	"$SCRIPT_DIR/record_monitor.sh" "$STREAM_ID" "$STREAM_PID" &
	RECORD_PID=$!
else
	log_info "RECORD_PATH not set - stream will NOT be recorded"
	RECORD_PID=""
fi

# Wait for mpv process to exit (either naturally or killed by watchdog)
log_debug "Monitoring mpv process $STREAM_PID"
wait $STREAM_PID
MPV_EXIT_CODE=$?
log_info "mpv process $STREAM_PID exited with code $MPV_EXIT_CODE"

# Clean up watchdog if still running
if ps -p $WATCHDOG_PID > /dev/null 2>&1; then
	log_debug "Terminating watchdog $WATCHDOG_PID"
	kill $WATCHDOG_PID 2>/dev/null
fi

# Clean up recording monitor if still running
if [ -n "$RECORD_PID" ] && ps -p $RECORD_PID > /dev/null 2>&1; then
	log_debug "Terminating recording monitor $RECORD_PID"
	kill $RECORD_PID 2>/dev/null
fi

log_info "spawn_monitor exiting for stream '$STREAM_NAME'"
