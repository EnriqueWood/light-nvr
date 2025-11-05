#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -n "$1" ]; then
  BASE_DIR="$1"
else
  source "$SCRIPT_DIR/config.env"
  BASE_DIR="$RECORD_PATH"
fi
echo "Recordings folder: $BASE_DIR"
DURATION_SCRIPT="$SCRIPT_DIR/duration.sh"

if [ ! -x "$DURATION_SCRIPT" ]; then
    echo "Error: duration.sh not found or not executable!"
    exit 1
fi

format_duration() {
    local seconds=$1

    if [ $seconds -eq 0 ]; then
        echo "No missing gaps"
        return
    fi

    if [ $seconds -lt 60 ]; then
        echo "${seconds}s"
    elif [ $seconds -lt 3600 ]; then
        local mins=$((seconds / 60))
        local secs=$((seconds % 60))
        if [ $secs -eq 0 ]; then
            echo "${mins}m"
        else
            echo "${mins}m ${secs}s"
        fi
    else
        local hours=$((seconds / 3600))
        local mins=$(((seconds % 3600) / 60))
        local secs=$((seconds % 60))

        local result="${hours}h"
        if [ $mins -gt 0 ] || [ $secs -gt 0 ]; then
            result="$result ${mins}m"
        fi
        if [ $secs -gt 0 ]; then
            result="$result ${secs}s"
        fi
        echo "$result"
    fi
}

for cam in $(find ${BASE_DIR}/* -type d -exec ls -d {} \; 2>/dev/null); do
    echo "Processing $cam..."
    total_time=0
    files=($(ls "$cam"/* 2>/dev/null | sort))
    file_count=$(ls -l "$cam" | grep -vE "^total " | wc -l)
    if [ ${#files[@]} -eq 0 ]; then
        echo "  No recordings found in $cam."
        continue
    fi

    first_file=$(basename "${files[0]}")
    TIMESTAMP_MASK='\d{4}-\d{2}-\d{2}_\d{2}[:-]\d{2}[-:]\d{2}'
    first_timestamp=$(echo "$first_file" | grep -oP "$TIMESTAMP_MASK")

    prev_end_time=""

    for file in "${files[@]}"; do
        filename=$(basename "$file")

        timestamp=$(echo "$filename" | grep -oP "$TIMESTAMP_MASK")
        if [[ -z "$timestamp" ]]; then
            echo "  [DEBUG] Unable to extract timestamp from: $filename"
            continue
        fi

        clean_timestamp=$(echo "$timestamp" | sed 's/_/ /g')

        start_time=$(date -d "$clean_timestamp" +%s 2>/dev/null)
        if [[ ! $start_time =~ ^[0-9]+$ ]]; then
            echo "  [DEBUG] Invalid timestamp conversion for $filename"
            echo "  [DEBUG] Extracted timestamp (cleaned): $clean_timestamp"
            continue
        fi

        duration=$(echo "$filename" | grep -oP '_length_\K[0-9]+(?=s\.ts)')

        if [[ -z "$duration" || ! $duration =~ ^[0-9]+$ ]]; then
            duration=$($DURATION_SCRIPT "$file" 2>/dev/null)
            if [[ ! $duration =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                echo "  [DEBUG] Invalid duration for $file"
                continue
            fi
            duration=$(echo "$duration" | awk '{print int($1+0.5)}')
        fi

        end_time=$(echo "$start_time + $duration" | bc 2>/dev/null)
        if [[ ! $end_time =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            echo "  [DEBUG] Invalid end time for $file"
            continue
        fi

        total_time="$(echo $total_time + $duration | bc)"
        if [[ -n "$prev_end_time" ]]; then
            gap=$(echo "$start_time - $prev_end_time" | bc 2>/dev/null)
            if [[ $(echo "$gap > 10" | bc -l) -eq 1 ]]; then
                gap_int=${gap%.*}
                gap_formatted=$(format_duration $gap_int)
                echo "  Missing gap: $(date -d @$prev_end_time '+%Y-%m-%d %H:%M:%S') → $(date -d @$start_time '+%Y-%m-%d %H:%M:%S') ($gap_formatted)"
            fi
        fi
        prev_end_time=$end_time
    done

    total_time_int=${total_time%.*}
    avg_time=$((total_time_int / file_count))
    total_formatted=$(format_duration $total_time_int)
    avg_formatted=$(format_duration $avg_time)
    echo "Total time recorded: $total_formatted in $file_count files ($avg_formatted avg per file)"
done
