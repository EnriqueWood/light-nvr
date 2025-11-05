#!/bin/bash

# Parse STREAM_CONNECTION_STREAMS array with optional names (format: URL###Name)

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/sanitize.sh"

declare -g -A STREAM_NAME_TO_URL
declare -g -A STREAM_URL_TO_NAME
declare -g -a STREAM_NAMES_ARRAY
declare -g -a STREAM_URLS_ARRAY

parse_stream_config() {
  local -a seen_names=()
  local -a seen_urls=()

  STREAM_NAME_TO_URL=()
  STREAM_URL_TO_NAME=()
  STREAM_NAMES_ARRAY=()
  STREAM_URLS_ARRAY=()

  if [ ${#STREAM_CONNECTION_STREAMS[@]} -eq 0 ]; then
    echo "ERROR: STREAM_CONNECTION_STREAMS is empty" >&2
    return 1
  fi

  local index=0
  for stream_entry in "${STREAM_CONNECTION_STREAMS[@]}"; do
    local url=""
    local name=""

    if [[ "$stream_entry" == *"###"* ]]; then
      url="${stream_entry%%###*}"
      name="${stream_entry##*###}"
      name="$(echo "$name" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

      if [ -z "$name" ]; then
        echo "ERROR: Stream $index has ### separator but empty name: $(sanitize_url "$url")" >&2
        return 1
      fi
    else
      url="$stream_entry"
      local stream_ip="$(echo "$url" | grep -Eo "[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}" | head -1)"
      if [ -n "$stream_ip" ]; then
        name="$stream_ip"
      else
        name="stream-$index"
      fi
    fi

    for seen_name in "${seen_names[@]}"; do
      if [ "$seen_name" = "$name" ]; then
        echo "ERROR: Duplicate stream name detected: '$name'" >&2
        echo "       Each stream must have a unique name" >&2
        return 1
      fi
    done

    for seen_url in "${seen_urls[@]}"; do
      if [ "$seen_url" = "$url" ]; then
        echo "ERROR: Duplicate stream URL detected: $(sanitize_url "$url")" >&2
        echo "       Each stream must have a unique URL" >&2
        return 1
      fi
    done

    seen_names+=("$name")
    seen_urls+=("$url")

    STREAM_NAME_TO_URL["$name"]="$url"
    STREAM_URL_TO_NAME["$url"]="$name"
    STREAM_NAMES_ARRAY+=("$name")
    STREAM_URLS_ARRAY+=("$url")

    index=$((index + 1))
  done

  return 0
}

get_url_by_name() {
  local name="$1"
  echo "${STREAM_NAME_TO_URL[$name]}"
}

get_name_by_url() {
  local url="$1"
  echo "${STREAM_URL_TO_NAME[$url]}"
}

get_name_by_index() {
  local index="$1"
  if [ "$index" -ge 0 ] && [ "$index" -lt "${#STREAM_NAMES_ARRAY[@]}" ]; then
    echo "${STREAM_NAMES_ARRAY[$index]}"
  fi
}

get_url_by_index() {
  local index="$1"
  if [ "$index" -ge 0 ] && [ "$index" -lt "${#STREAM_URLS_ARRAY[@]}" ]; then
    echo "${STREAM_URLS_ARRAY[$index]}"
  fi
}

get_stream_count() {
  echo "${#STREAM_NAMES_ARRAY[@]}"
}

stream_name_exists() {
  local name="$1"
  [ -n "${STREAM_NAME_TO_URL[$name]}" ]
}

stream_url_exists() {
  local url="$1"
  [ -n "${STREAM_URL_TO_NAME[$url]}" ]
}
