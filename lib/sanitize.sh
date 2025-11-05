#!/bin/bash

# Sanitize URLs to prevent credentials from appearing in logs

sanitize_url() {
  local url="$1"
  local sanitized="$url"

  # Replace user:pass@ with ****:****@
  if [[ "$sanitized" =~ ^([a-zA-Z]+://)([^:]+):([^@]+)@(.*)$ ]]; then
    local protocol="${BASH_REMATCH[1]}"
    local user="${BASH_REMATCH[2]}"
    local password="${BASH_REMATCH[3]}"
    local rest="${BASH_REMATCH[4]}"

    sanitized="${protocol}****:****@${rest}"

    # Some cameras put credentials in the path (e.g., /user=admin_password=secret_channel=1)
    sanitized=$(echo "$sanitized" | sed "s/user=${user}_/user=****_/g" | sed "s/user=${user}\([&?/]\)/user=****\1/g")
    sanitized=$(echo "$sanitized" | sed "s/password=${password}_/password=****_/g" | sed "s/password=${password}\([&?/]\)/password=****\1/g")
  fi

  echo "$sanitized"
}

sanitize_text() {
  local text="$1"
  echo "$text" | sed -E 's|([a-zA-Z]+://)([^:]+):([^@]+)@|\1****:****@|g'
}

extract_ip() {
  local url="$1"
  local without_protocol="${url#*://}"
  local without_creds="${without_protocol#*@}"
  echo "$without_creds" | grep -oE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -n 1
}

get_stream_identifier() {
  local url="$1"
  local ip=$(extract_ip "$url")

  if [ -n "$ip" ]; then
    echo "$ip"
  else
    sanitize_url "$url"
  fi
}

export -f sanitize_url
export -f sanitize_text
export -f extract_ip
export -f get_stream_identifier
