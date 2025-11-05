#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/stream_config.sh"

STREAM_ID=$1
STREAM_PID=$2
SOCKET_PATH="/tmp/mpvsocket-$STREAM_ID"
CHECK_INTERVAL=10

pid_exists() {
  ps -p "$STREAM_PID" > /dev/null 2>&1
}

source "$SCRIPT_DIR/config.env"

MAX_RECORD_SECONDS_IN_SEGMENT=${RECORD_SEGMENT_SECONDS:-600}

if [ -z "$RECORD_PATH" ]; then
  echo "ERROR: RECORD_PATH not set in config.env" >&2
  exit 1
fi

USE_RAM_BUFFER=${RECORD_USE_RAM_BUFFER:-false}
RAM_BUFFER_SIZE_MB=${RECORD_RAM_BUFFER_SIZE_MB:-512}
RAM_BUFFER_BASE="/dev/shm/nvr-ram-buffer"

if ! parse_stream_config; then
  echo "ERROR: Failed to parse stream configuration" >&2
  exit 1
fi

STREAM_NAME=$(get_name_by_index "$STREAM_ID")

if [ -z "$STREAM_NAME" ]; then
  echo "ERROR: Could not find stream at index $STREAM_ID" >&2
  exit 1
fi

init_logging "record-$STREAM_NAME" "pid: $STREAM_PID"

STREAM_FOLDER_NAME="$(echo "$STREAM_NAME" | tr ' ' '_' | tr -cd '[:alnum:]_-')"
STREAM_RECORD_FOLDER="${RECORD_PATH}/$STREAM_FOLDER_NAME"

log_info "Creating recording folder: $STREAM_RECORD_FOLDER"
mkdir -p "$STREAM_RECORD_FOLDER"

RAM_BUFFER_FOLDER=""
if [ "$USE_RAM_BUFFER" = "true" ]; then
  AVAILABLE_RAM_KB=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
  AVAILABLE_RAM_MB=$((AVAILABLE_RAM_KB / 1024))
  REQUIRED_RAM_MB=$((RAM_BUFFER_SIZE_MB + 2048))  # Buffer size + 2GB safety margin

  if [ $AVAILABLE_RAM_MB -lt $REQUIRED_RAM_MB ]; then
    log_warning "Insufficient RAM for buffer (available: ${AVAILABLE_RAM_MB}MB, required: ${REQUIRED_RAM_MB}MB). Disabling RAM buffer"
    USE_RAM_BUFFER=false
  else
    # Use /dev/shm which is always available and RAM-based on Linux
    RAM_BUFFER_FOLDER="${RAM_BUFFER_BASE}/${STREAM_FOLDER_NAME}"
    mkdir -p "$RAM_BUFFER_FOLDER"
    log_info "Using /dev/shm RAM buffer at $RAM_BUFFER_FOLDER (available RAM: ${AVAILABLE_RAM_MB}MB)"

    # Recover any leftover segments from previous sessions
    log_debug "Checking for leftover segments in RAM buffer from previous sessions"
    RECOVERED_COUNT=0
    shopt -s nullglob
    for LEFTOVER_FILE in "$RAM_BUFFER_FOLDER"/*.ts; do
      if [ -f "$LEFTOVER_FILE" ]; then
        DISK_FILE="${STREAM_RECORD_FOLDER}/$(basename "$LEFTOVER_FILE")"
        log_info "Recovering leftover segment from RAM: $(basename "$LEFTOVER_FILE")"
        if mv "$LEFTOVER_FILE" "$DISK_FILE" 2>/dev/null; then
          RECOVERED_COUNT=$((RECOVERED_COUNT + 1))
          log_info "Recovered segment to disk: $(basename "$DISK_FILE")"
        else
          log_error "Failed to recover segment: $(basename "$LEFTOVER_FILE")"
        fi
      fi
    done
    shopt -u nullglob

    if [ $RECOVERED_COUNT -gt 0 ]; then
      log_info "Recovered $RECOVERED_COUNT leftover segment(s) from RAM buffer"
    else
      log_debug "No leftover segments found in RAM buffer"
    fi
  fi
fi

if [ "$USE_RAM_BUFFER" = "true" ]; then
  log_info "Recording stream '$STREAM_NAME' to RAM buffer: $RAM_BUFFER_FOLDER (segment duration: ${MAX_RECORD_SECONDS_IN_SEGMENT}s)"
else
  log_info "Recording stream '$STREAM_NAME' to folder: $STREAM_RECORD_FOLDER (segment duration: ${MAX_RECORD_SECONDS_IN_SEGMENT}s)"
fi

CURRENT_RECORD_FILE=""
RECORD_START_TIME=0

# Function to transfer completed segments from RAM to disk
transfer_segment_to_disk() {
  local RAM_FILE="$1"

  if [ ! -f "$RAM_FILE" ]; then
    log_warning "RAM file does not exist, skipping transfer: $RAM_FILE"
    return 1
  fi

  # Get video duration using ffprobe
  local DURATION_SECONDS=""
  if command -v ffprobe >/dev/null 2>&1; then
    DURATION_SECONDS=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$RAM_FILE" 2>/dev/null | awk '{print int($1+0.5)}')
  fi

  # Build the new filename with duration
  local BASENAME=$(basename "$RAM_FILE" .ts)
  local NEW_FILENAME
  if [ -n "$DURATION_SECONDS" ] && [ "$DURATION_SECONDS" -gt 0 ]; then
    NEW_FILENAME="${BASENAME}_length_${DURATION_SECONDS}s.ts"
    log_debug "Video duration: ${DURATION_SECONDS}s"
  else
    NEW_FILENAME="${BASENAME}.ts"
    log_warning "Could not determine video duration, using original filename"
  fi

  local DISK_FILE="${STREAM_RECORD_FOLDER}/${NEW_FILENAME}"

  log_debug "Transferring segment from RAM to disk: $(basename "$RAM_FILE") -> ${NEW_FILENAME}"
  if mv "$RAM_FILE" "$DISK_FILE" 2>/dev/null; then
    log_info "Segment transferred to disk: ${NEW_FILENAME}"
    return 0
  else
    log_error "Failed to transfer segment to disk: $(basename "$RAM_FILE")"
    return 1
  fi
}

# Function to rename file with duration suffix
rename_file_with_duration() {
  local ORIGINAL_FILE="$1"

  if [ ! -f "$ORIGINAL_FILE" ]; then
    log_warning "File does not exist, skipping rename: $ORIGINAL_FILE"
    return 1
  fi

  # Get video duration using ffprobe
  local DURATION_SECONDS=""
  if command -v ffprobe >/dev/null 2>&1; then
    DURATION_SECONDS=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$ORIGINAL_FILE" 2>/dev/null | awk '{print int($1+0.5)}')
  fi

  # Build the new filename with duration
  local DIR=$(dirname "$ORIGINAL_FILE")
  local BASENAME=$(basename "$ORIGINAL_FILE" .ts)
  local NEW_FILENAME

  if [ -n "$DURATION_SECONDS" ] && [ "$DURATION_SECONDS" -gt 0 ]; then
    NEW_FILENAME="${BASENAME}_length_${DURATION_SECONDS}s.ts"
    local NEW_FILE="${DIR}/${NEW_FILENAME}"
    log_debug "Renaming with duration: $(basename "$ORIGINAL_FILE") -> ${NEW_FILENAME} (${DURATION_SECONDS}s)"

    if mv "$ORIGINAL_FILE" "$NEW_FILE" 2>/dev/null; then
      log_info "File renamed with duration: ${NEW_FILENAME}"
      return 0
    else
      log_error "Failed to rename file: $(basename "$ORIGINAL_FILE")"
      return 1
    fi
  else
    log_warning "Could not determine video duration for $(basename "$ORIGINAL_FILE"), keeping original filename"
    return 1
  fi
}

# Cleanup function for graceful and abrupt exits
cleanup_and_exit() {
  local EXIT_CODE=${1:-0}
  log_info "Cleanup initiated for '$STREAM_NAME' (exit code: $EXIT_CODE)"

  # Stop current recording
  if [ -n "$CURRENT_RECORD_FILE" ] && [ -S "$SOCKET_PATH" ]; then
    log_info "Stopping current recording segment"
    echo '{"command": ["set_property", "stream-record", ""]}' | socat -t 2 - "$SOCKET_PATH" 2>/dev/null || true
  fi

  # If RAM buffer is enabled, transfer all segments from RAM to disk
  if [ "$USE_RAM_BUFFER" = "true" ] && [ -n "$RAM_BUFFER_FOLDER" ] && [ -d "$RAM_BUFFER_FOLDER" ]; then
    log_info "Transferring remaining segments from RAM buffer to disk"

    # Ensure disk folder exists before transfer
    mkdir -p "$STREAM_RECORD_FOLDER" 2>/dev/null || true

    local TRANSFERRED=0
    local FAILED=0

    shopt -s nullglob
    for RAM_FILE in "$RAM_BUFFER_FOLDER"/*.ts; do
      if [ -f "$RAM_FILE" ]; then
        if transfer_segment_to_disk "$RAM_FILE"; then
          TRANSFERRED=$((TRANSFERRED + 1))
        else
          FAILED=$((FAILED + 1))
        fi
      fi
    done
    shopt -u nullglob

    if [ $TRANSFERRED -gt 0 ]; then
      log_info "Transferred $TRANSFERRED segment(s) from RAM to disk"
    fi
    if [ $FAILED -gt 0 ]; then
      log_warning "Failed to transfer $FAILED segment(s)"
    fi

    # Clean up RAM buffer directory
    if rmdir "$RAM_BUFFER_FOLDER" 2>/dev/null; then
      log_debug "Removed RAM buffer directory"
    fi
  else
    # If RAM buffer is disabled, rename current file on disk with duration
    if [ -n "$CURRENT_RECORD_FILE" ] && [ -f "$CURRENT_RECORD_FILE" ]; then
      log_info "Renaming current segment with duration"
      rename_file_with_duration "$CURRENT_RECORD_FILE"
    fi
  fi

  log_info "Cleanup completed for '$STREAM_NAME'"
  exit "$EXIT_CODE"
}

# Set up trap to handle abrupt terminations
trap 'cleanup_and_exit 143' SIGTERM  # Kill signal (default kill)
trap 'cleanup_and_exit 130' SIGINT   # Ctrl+C
trap 'cleanup_and_exit 1' SIGHUP     # Hangup (terminal closed)
trap 'cleanup_and_exit $?' EXIT      # Any other exit (script errors, normal exit, etc.)

start_new_segment() {
  # Transfer previous segment from RAM to disk if using RAM buffer
  local PREVIOUS_FILE="$CURRENT_RECORD_FILE"

  # Determine where to write the new segment
  local TIMESTAMP=$(date +%Y-%m-%d_%H:%M:%S)
  local NEW_FILE
  if [ "$USE_RAM_BUFFER" = "true" ] && [ -n "$RAM_BUFFER_FOLDER" ]; then
    NEW_FILE="${RAM_BUFFER_FOLDER}/${TIMESTAMP}.ts"
  else
    NEW_FILE="${STREAM_RECORD_FOLDER}/${TIMESTAMP}.ts"
  fi

  local MAX_RETRIES=3
  local retry=0

  log_debug "Attempting to start new recording segment: $(basename "$NEW_FILE")"

  while [ $retry -lt $MAX_RETRIES ]; do
    if [ ! -S "$SOCKET_PATH" ]; then
      log_warning "Socket $SOCKET_PATH does not exist. Cannot start recording (attempt $((retry+1))/$MAX_RETRIES)"
      retry=$((retry + 1))
      sleep 2
      continue
    fi

    RESULT=$(echo '{"command": ["set_property", "stream-record", "'"$NEW_FILE"'"]}' | socat - "$SOCKET_PATH" 2>/dev/null)
    ERROR=$(echo "$RESULT" | jq -r '.error' 2>/dev/null)

    if [ "$ERROR" = "success" ]; then
      CURRENT_RECORD_FILE="$NEW_FILE"
      RECORD_START_TIME=$(date +%s)
      log_info "Started new recording segment for '$STREAM_NAME': $(basename "$NEW_FILE")"

      # Handle previous segment based on whether RAM buffer is used
      if [ -n "$PREVIOUS_FILE" ] && [ -f "$PREVIOUS_FILE" ]; then
        if [ "$USE_RAM_BUFFER" = "true" ]; then
          # Transfer previous completed segment from RAM to disk
          mkdir -p "$STREAM_RECORD_FOLDER"
          transfer_segment_to_disk "$PREVIOUS_FILE"
        else
          # Rename previous segment on disk with duration
          rename_file_with_duration "$PREVIOUS_FILE"
        fi
      fi

      return 0
    else
      log_warning "Failed to start recording for '$STREAM_NAME': $ERROR (attempt $((retry+1))/$MAX_RETRIES)"
      retry=$((retry + 1))
      sleep 2
    fi
  done

  log_error "Failed to start recording for '$STREAM_NAME' after $MAX_RETRIES attempts. Recording will be retried in next cycle"
  return 1
}

# Main monitoring loop
log_info "Recording monitor started for '$STREAM_NAME' (check interval: ${CHECK_INTERVAL}s)"

# Wait for socket to be ready with timeout
MAX_SOCKET_WAIT=30
log_debug "Waiting for socket to be ready (max ${MAX_SOCKET_WAIT}s)"
SOCKET_WAIT=0
while [ $SOCKET_WAIT -lt $MAX_SOCKET_WAIT ]; do
  if [ -S "$SOCKET_PATH" ]; then
    # Verify socket is responsive
    TEST_RESULT=$(echo '{"command": ["get_property", "path"]}' | socat -t 2 - "$SOCKET_PATH" 2>/dev/null)
    if [ -n "$TEST_RESULT" ]; then
      log_info "Socket is ready and responsive for '$STREAM_NAME' after ${SOCKET_WAIT}s"
      break
    fi
  fi
  SOCKET_WAIT=$((SOCKET_WAIT + 1))
  sleep 1
done

if [ $SOCKET_WAIT -ge $MAX_SOCKET_WAIT ]; then
  log_error "Socket did not become ready for '$STREAM_NAME' within $MAX_SOCKET_WAIT seconds. Recording monitor exiting"
  exit 1
fi

while true; do
  if ! pid_exists; then
    log_info "mpv process no longer exists for '$STREAM_NAME'. Recording monitor exiting"
    cleanup_and_exit 0
  fi

  if [ ! -S "$SOCKET_PATH" ]; then
    log_error "Socket disappeared for '$STREAM_NAME'. Recording monitor exiting"
    cleanup_and_exit 1
  fi

  CURRENT_TIME=$(date +%s)
  TIME_DIFF=$((CURRENT_TIME - RECORD_START_TIME))

  # Start first segment or rotate if needed
  if [ -z "$CURRENT_RECORD_FILE" ]; then
    log_info "No active recording. Starting first segment"
    start_new_segment
  elif [ $TIME_DIFF -ge $MAX_RECORD_SECONDS_IN_SEGMENT ]; then
    log_info "Segment duration ($TIME_DIFF seconds) exceeded limit ($MAX_RECORD_SECONDS_IN_SEGMENT seconds). Rotating to new segment"
    start_new_segment
  else
    log_debug "Current segment: $(basename "${CURRENT_RECORD_FILE:-none}"), duration: ${TIME_DIFF}s / ${MAX_RECORD_SECONDS_IN_SEGMENT}s"
  fi

  sleep $CHECK_INTERVAL
done
