#!/bin/bash

LOGS_FOLDER="${LOGS_FOLDER:-/tmp/cam-monitor/logs}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-7}"
LOG_SCRIPT_NAME="${LOG_SCRIPT_NAME:-}"
LOG_CONTEXT="${LOG_CONTEXT:-}"
LOG_DATE="${LOG_DATE:-$(date '+%Y-%m-%d')}"
LOG_FILE="${LOG_FILE:-}"

mkdir -p "$LOGS_FOLDER"

log_timestamp() {
  date '+%Y-%m-%d %H:%M:%S.%3N'
}

init_logging() {
  LOG_SCRIPT_NAME="$1"
  LOG_CONTEXT="${2:-}"
  LOG_FILE="$LOGS_FOLDER/${LOG_SCRIPT_NAME}-${LOG_DATE}.log"
  cleanup_old_logs
  log_info "Logging initialized"
}

cleanup_old_logs() {
  if [ "$LOG_RETENTION_DAYS" -le 0 ]; then
    return
  fi

  local deleted_count=0
  while IFS= read -r -d '' old_log; do
    rm -f "$old_log" 2>/dev/null && deleted_count=$((deleted_count + 1))
  done < <(find "$LOGS_FOLDER" -type f -name "*.log" -mtime "+${LOG_RETENTION_DAYS}" -print0 2>/dev/null)

  if [ $deleted_count -gt 0 ]; then
    _log "INFO" "Cleaned up $deleted_count log files older than $LOG_RETENTION_DAYS days"
  fi
}

_log() {
  local severity="$1"
  shift
  local message="$@"

  # Check if log file needs rotation
  local current_date=$(date '+%Y-%m-%d')
  if [ "$current_date" != "$LOG_DATE" ]; then
    LOG_DATE="$current_date"
    LOG_FILE="$LOGS_FOLDER/${LOG_SCRIPT_NAME}-${LOG_DATE}.log"
    cleanup_old_logs
  fi

  local log_entry="$(log_timestamp) [$severity]"

  if [ -n "$LOG_SCRIPT_NAME" ]; then
    log_entry="$log_entry [$LOG_SCRIPT_NAME]"
  fi

  if [ -n "$LOG_CONTEXT" ]; then
    log_entry="$log_entry [$LOG_CONTEXT]"
  fi

  log_entry="$log_entry $message"

  if [ -z "$LOG_FILE" ]; then
    echo "[ERROR] Logging called before init_logging. Caller: ${FUNCNAME[2]}, Script: $0" >&2
    LOG_FILE="$LOGS_FOLDER/uninitialized-$(date '+%Y-%m-%d').log"
    mkdir -p "$LOGS_FOLDER"
  fi

  echo "$log_entry" | tee -a "$LOG_FILE"
}

log_debug() {
  _log "DEBUG" "$@"
}

log_info() {
  _log "INFO" "$@"
}

log_warning() {
  _log "WARNING" "$@"
}

log_error() {
  _log "ERROR" "$@"
}

update_log_context() {
  LOG_CONTEXT="$1"
}

get_log_file() {
  echo "$LOG_FILE"
}

get_logs_folder() {
  echo "$LOGS_FOLDER"
}

export -f log_timestamp
export -f init_logging
export -f cleanup_old_logs
export -f log_debug
export -f log_info
export -f log_warning
export -f log_error
export -f update_log_context
export -f get_log_file
export -f get_logs_folder
