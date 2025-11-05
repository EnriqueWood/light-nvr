#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/logging.sh"

init_logging "quota"

RECORD_PATH=$1
RECORD_MAX_SIZE_MB=${RECORD_MAX_SIZE_MB:-}
CHECK_INTERVAL=${RECORD_QUOTA_CHECK_SECONDS:-10}

if [ -z "$RECORD_PATH" ]; then
  log_error "RECORD_PATH not provided. Exiting"
  exit 1
fi

if [ -z "$RECORD_MAX_SIZE_MB" ]; then
  log_info "RECORD_MAX_SIZE_MB not set. Quota monitoring disabled"
  exit 0
fi

if [ ! -d "$RECORD_PATH" ]; then
  log_warning "Recording path '$RECORD_PATH' does not exist. Creating it"
  mkdir -p "$RECORD_PATH"
  log_debug "Created directory: $RECORD_PATH"
fi

log_info "Quota monitor started. Path: $RECORD_PATH, Max size: ${RECORD_MAX_SIZE_MB}MB, Check interval: ${CHECK_INTERVAL}s"

MAX_SIZE_BYTES=$((RECORD_MAX_SIZE_MB * 1024 * 1024))

while true; do
  if [ ! -d "$RECORD_PATH" ]; then
    log_warning "Recording path disappeared. Recreating: $RECORD_PATH"
    mkdir -p "$RECORD_PATH"
    log_debug "Directory recreated successfully"
  fi

  log_debug "Calculating total size of recording files in $RECORD_PATH"
  TOTAL_SIZE=$(find "$RECORD_PATH" -type f -name "*.ts" -exec stat -c%s {} + 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
  TOTAL_SIZE_MB=$((TOTAL_SIZE / 1024 / 1024))

  FILE_COUNT=$(find "$RECORD_PATH" -type f -name "*.ts" 2>/dev/null | wc -l)

  if [ $TOTAL_SIZE -gt $MAX_SIZE_BYTES ]; then
    EXCESS_BYTES=$((TOTAL_SIZE - MAX_SIZE_BYTES))
    EXCESS_MB=$((EXCESS_BYTES / 1024 / 1024))
    log_warning "Quota exceeded: ${TOTAL_SIZE_MB}MB / ${RECORD_MAX_SIZE_MB}MB (excess: ${EXCESS_MB}MB)"

    DELETED_SIZE=0
    DELETED_COUNT=0

    TEMP_FILE_LIST="/tmp/quota_files_$$.txt"
    find "$RECORD_PATH" -type f -name "*.ts" -printf '%T@ %s %p\n' | sort -n > "$TEMP_FILE_LIST"

    TOTAL_FILES_FOUND=$(wc -l < "$TEMP_FILE_LIST")
    log_info "Found $TOTAL_FILES_FOUND recording files. Need to delete at least ${EXCESS_MB}MB..."

    while read -r timestamp filesize filepath; do
      if [ $DELETED_SIZE -lt $EXCESS_BYTES ]; then
        if lsof "$filepath" > /dev/null 2>&1; then
          log_debug "Skipping $(basename "$filepath") (currently in use by recording process)"
          continue
        fi

        FILE_SIZE_MB=$((filesize / 1024 / 1024))

        log_info "Deleting old recording: $(basename "$filepath") (${FILE_SIZE_MB}MB)"
        if rm -f "$filepath" 2>/dev/null; then
          DELETED_SIZE=$((DELETED_SIZE + filesize))
          DELETED_COUNT=$((DELETED_COUNT + 1))
        else
          log_error "Failed to delete $filepath"
        fi
      else
        break
      fi
    done < "$TEMP_FILE_LIST"

    rm -f "$TEMP_FILE_LIST"

    NEW_TOTAL_SIZE=$(find "$RECORD_PATH" -type f -name "*.ts" -exec stat -c%s {} + 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
    NEW_TOTAL_SIZE_MB=$((NEW_TOTAL_SIZE / 1024 / 1024))
    NEW_FILE_COUNT=$(find "$RECORD_PATH" -type f -name "*.ts" 2>/dev/null | wc -l)
    log_info "Cleanup complete. Deleted $DELETED_COUNT files. New total: ${NEW_TOTAL_SIZE_MB}MB / ${RECORD_MAX_SIZE_MB}MB ($NEW_FILE_COUNT files remaining)"
  else
    log_debug "Quota check: ${TOTAL_SIZE_MB}MB / ${RECORD_MAX_SIZE_MB}MB ($FILE_COUNT files) - OK"
  fi

  sleep $CHECK_INTERVAL
done
