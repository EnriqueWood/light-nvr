#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/sanitize.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/stream_config.sh"

init_logging "main"

cleanup() {
  log_info "Cleanup initiated - terminating all processes"

  # Kill quota monitor if we have its PID
  if [ -n "$QUOTA_MONITOR_PID" ] && ps -p "$QUOTA_MONITOR_PID" > /dev/null 2>&1; then
    log_info "Stopping quota monitor (PID: $QUOTA_MONITOR_PID)"
    kill "$QUOTA_MONITOR_PID" 2>/dev/null
  fi

  # Graceful shutdown with fallback to force kill
  # Use -f flag for process names longer than 15 chars
  for process in watchdog.sh spawn_monitor.sh record_monitor.sh quota_monitor.sh mpv; do
    if pgrep -f "$process" > /dev/null 2>&1; then
      local count=$(pgrep -f "$process" 2>/dev/null | wc -l)
      log_info "Stopping $count $process processes"
      pkill -TERM -f "$process" 2>/dev/null
    fi
  done

  # Give processes time to terminate gracefully
  # record_monitor.sh needs time to transfer files from RAM to disk and calculate durations
  log_info "Waiting for graceful termination (checking every 0.5s, max 15s)..."

  local iterations=0
  local max_iterations=30  # 30 * 0.5s = 15s
  while [ $iterations -lt $max_iterations ]; do
    local remaining=0
    for process in watchdog.sh spawn_monitor.sh record_monitor.sh quota_monitor.sh mpv; do
      local count=$(pgrep -f "$process" 2>/dev/null | wc -l)
      remaining=$((remaining + count))
    done

    if [ $remaining -eq 0 ]; then
      local wait_time=$(awk "BEGIN {print $iterations * 0.5}")
      log_info "All processes terminated gracefully after ${wait_time}s"
      break
    fi

    sleep 0.5
    iterations=$((iterations + 1))
  done

  # Force kill any remaining processes after timeout
  for process in watchdog.sh spawn_monitor.sh record_monitor.sh quota_monitor.sh mpv; do
    if pgrep -f "$process" > /dev/null 2>&1; then
      local count=$(pgrep -f "$process" 2>/dev/null | wc -l)
      log_warning "Force killing $count remaining $process processes after ${max_wait}s timeout"
      pkill -9 -f "$process" 2>/dev/null
    fi
  done

  # Clean up socket files
  local socket_count=$(ls -1 /tmp/mpvsocket-* 2>/dev/null | wc -l)
  if [ $socket_count -gt 0 ]; then
    log_debug "Cleaning up $socket_count socket files"
    rm -f /tmp/mpvsocket-* 2>/dev/null
  fi

  log_info "Cleanup complete"
  exit
}

trap cleanup SIGINT EXIT

LAYOUTS_DIR="$HOME/.light-nvr/layouts"

validate_config() {
  local errors=0

  # Validate CONNECTION_HEALTHCHECK_SECONDS is a positive number
  if ! [[ "${CONNECTION_HEALTHCHECK_SECONDS}" =~ ^[0-9]+$ ]] || [ "${CONNECTION_HEALTHCHECK_SECONDS}" -le 0 ]; then
    log_error " CONNECTION_HEALTHCHECK_SECONDS must be a positive integer (current: ${CONNECTION_HEALTHCHECK_SECONDS})"
    errors=$((errors + 1))
  fi

  # Validate RECORD_SEGMENT_SECONDS if recording is enabled
  if [ -n "${RECORD_PATH}" ]; then
    if ! [[ "${RECORD_SEGMENT_SECONDS:-600}" =~ ^[0-9]+$ ]] || [ "${RECORD_SEGMENT_SECONDS:-600}" -le 0 ]; then
      log_error " RECORD_SEGMENT_SECONDS must be a positive integer (current: ${RECORD_SEGMENT_SECONDS:-600})"
      errors=$((errors + 1))
    fi
  fi

  # Validate RECORD_MAX_SIZE_MB if set
  if [ -n "${RECORD_MAX_SIZE_MB}" ]; then
    if ! [[ "${RECORD_MAX_SIZE_MB}" =~ ^[0-9]+$ ]] || [ "${RECORD_MAX_SIZE_MB}" -le 0 ]; then
      log_error " RECORD_MAX_SIZE_MB must be a positive integer (current: ${RECORD_MAX_SIZE_MB})"
      errors=$((errors + 1))
    fi
  fi

  # Validate RECORD_QUOTA_CHECK_SECONDS if set
  if [ -n "${RECORD_QUOTA_CHECK_SECONDS}" ]; then
    if ! [[ "${RECORD_QUOTA_CHECK_SECONDS}" =~ ^[0-9]+$ ]] || [ "${RECORD_QUOTA_CHECK_SECONDS}" -le 0 ]; then
      log_error " RECORD_QUOTA_CHECK_SECONDS must be a positive integer (current: ${RECORD_QUOTA_CHECK_SECONDS})"
      errors=$((errors + 1))
    fi
  fi

  return $errors
}

ROUNDS=1
QUOTA_STARTED=0
QUOTA_MONITOR_PID=""
while true; do
  log_info "Round ${ROUNDS} started"
  source "$SCRIPT_DIR/config.env"

  # Validate configuration on first round
  if [ $ROUNDS -eq 1 ]; then
    if ! validate_config; then
      log_error "Configuration validation failed. Exiting"
      exit 1
    fi

    # Parse and validate stream configuration
    log_debug "Parsing stream configuration"
    if ! parse_stream_config; then
      log_error "Stream configuration validation failed. Exiting"
      exit 1
    fi
    local stream_count=$(get_stream_count)
    log_info "Configuration validated successfully ($stream_count streams configured)"

    # Log stream names for visibility
    for ((i = 0; i < stream_count; i++)); do
      local name=$(get_name_by_index "$i")
      local url=$(get_url_by_index "$i")
      log_info "  Stream $i: '$name' -> $(sanitize_url "$url")"
    done
  fi

  source "$SCRIPT_DIR/calculate_geometries.sh"
  STREAM_COUNT=${#STREAM_GEOMETRIES[@]}
  CONNECTED=0

  # Manage quota monitor based on current config
  if [ -n "${RECORD_PATH}" ] && [ -n "${RECORD_MAX_SIZE_MB}" ]; then
    if [ -z "$QUOTA_MONITOR_PID" ] || ! ps -p "$QUOTA_MONITOR_PID" > /dev/null 2>&1; then
      log_info "Starting quota monitor for recording path: $RECORD_PATH (max: ${RECORD_MAX_SIZE_MB}MB)"
      "$SCRIPT_DIR/quota_monitor.sh" "$RECORD_PATH" &
      QUOTA_MONITOR_PID=$!
      log_debug "Quota monitor started with PID: $QUOTA_MONITOR_PID"
      QUOTA_STARTED=1
    fi
  else
    # Stop quota monitor if config changed to disable it
    if [ -n "$QUOTA_MONITOR_PID" ] && ps -p "$QUOTA_MONITOR_PID" > /dev/null 2>&1; then
      log_info "Quota monitor no longer needed (config changed). Stopping PID $QUOTA_MONITOR_PID"
      kill "$QUOTA_MONITOR_PID" 2>/dev/null
      QUOTA_MONITOR_PID=""
    fi
  fi
  for ((i = 0; i < STREAM_COUNT; i++)); do
    item="${STREAM_GEOMETRIES[i]}"
    url="${item%% *}"
    name=$(get_name_by_url "$url")
    if [ -z "$name" ]; then
      log_warning "Could not find name for stream $i with URL $(sanitize_url "$url"), using fallback"
      name="stream-$i"
    fi

    log_info "Checking if stream '$name' is running in mpv"
    # Check for spawn_monitor process with stream index
    ps -fea | grep -v "grep" | grep -qF "$SCRIPT_DIR/spawn_monitor.sh $i " && ((CONNECTED++))
  done
  log_info "$CONNECTED out of $STREAM_COUNT streams are connected"

  # Check if a layout should be applied
  if [[ -n "${LAYOUT:-}" ]]; then
    LAYOUT_FILE="$LAYOUTS_DIR/$LAYOUT.layout"

    if [[ ! -f "$LAYOUT_FILE" ]]; then
      log_error "Layout file '$LAYOUT_FILE' does not exist. Skipping layout application"
    else
      LAYOUT_STREAM_COUNT=$(wc -l < "$LAYOUT_FILE")
      if [[ "$LAYOUT_STREAM_COUNT" -lt "$STREAM_COUNT" ]]; then
        log_error "Layout '$LAYOUT' has only $LAYOUT_STREAM_COUNT streams, but $STREAM_COUNT streams are required. Skipping layout application"
      else
        log_info "Applying layout from $LAYOUT_FILE ($LAYOUT_STREAM_COUNT streams)"
        mapfile -t LAYOUT_GEOMETRIES < "$LAYOUT_FILE"
      fi
    fi
  fi

  for ((i = 0; i < STREAM_COUNT; i++)); do
    item="${STREAM_GEOMETRIES[i]}"
    url="${item%% *}"
    geometry="${item##* }"
    name=$(get_name_by_url "$url")
    if [ -z "$name" ]; then
      log_warning "Could not find name for stream $i with URL $(sanitize_url "$url"), using fallback"
      name="stream-$i"
    fi

    # If layout is applied, override geometry from the layout file
    if [[ -n "${LAYOUT_GEOMETRIES:-}" && $i -lt ${#LAYOUT_GEOMETRIES[@]} ]]; then
      geometry="${LAYOUT_GEOMETRIES[$i]}"
    fi

    # Check if a spawn_monitor is already running for this stream (by index)
    if ps -fea | grep -v "grep" | grep -qF "$SCRIPT_DIR/spawn_monitor.sh $i "; then
      log_debug "spawn_monitor already running for stream '$name' (index $i), skipping"
    else
      log_info "Round $ROUNDS: Stream '$name' not connected... retrying connection..."
      log_debug "Launching spawn_monitor.sh for stream $i ('$name') with geometry: $geometry"
      "$SCRIPT_DIR/spawn_monitor.sh" "$i" "$geometry" &
    fi
  done

  log_info "Round $ROUNDS: Checking again in $CONNECTION_HEALTHCHECK_SECONDS seconds..."
  sleep "$CONNECTION_HEALTHCHECK_SECONDS"

  ((ROUNDS++))
done
