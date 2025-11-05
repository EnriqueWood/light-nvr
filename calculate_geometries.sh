#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/sanitize.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/stream_config.sh"

CALC_GEOM_LOGS_FOLDER="${LOGS_FOLDER:-/tmp/cam-monitor/logs}"
CALC_GEOM_LOG_FILE="$CALC_GEOM_LOGS_FOLDER/main.log"
mkdir -p "$CALC_GEOM_LOGS_FOLDER"

log() {
    local message="$@"
    local level="INFO"
    if [[ "$message" == ERROR:* ]]; then
        level="ERROR"
        message="${message#ERROR: }"
    fi
    echo "$(log_timestamp) [$level] [calculate_geometries] $message" | tee -a "$CALC_GEOM_LOG_FILE"
}

if [ ${#STREAM_CONNECTION_STREAMS[@]} -lt 2 ]; then
  log "ERROR: STREAM_CONNECTION_STREAMS must have at least 2 streams defined"
  exit 1
fi

if ! parse_stream_config; then
  log "ERROR: Failed to parse stream configuration"
  exit 1
fi

SCREEN_WIDTH=$(echo "$BASE_SCREEN_WIDTH - $SCREEN_LEFT" | bc | sed 's/\..*//g')
SCREEN_HEIGHT=$(echo "$BASE_SCREEN_HEIGHT - $SCREEN_TOP" | bc | sed 's/\..*//g')

STREAM_GEOMETRIES=()

calculate_dimensions() {
    local width=$1
    local height=$2
    local max_width=$3
    local max_height=$4
    local aspect_ratio=$(echo "scale=4; $width / $height" | bc)

    local new_width=$(echo "scale=4; $max_height * $aspect_ratio" | bc)
    if (( $(echo "$new_width <= $max_width" | bc -l) )); then
        echo "${new_width%.*}x$max_height"
    else
        local new_height=$(echo "scale=4; $max_width / $aspect_ratio" | bc)
        echo "${max_width}x${new_height%.*}"
    fi
}


STREAM_0_WIDTH_TO_HEIGHT_RATIO=1.125
STREAM0_WIDTH=$(echo "0.5 * $SCREEN_WIDTH" | bc | sed 's/\..*//g')
STREAM0_HEIGHT=$(echo "$STREAM0_WIDTH * $STREAM_0_WIDTH_TO_HEIGHT_RATIO" | bc | sed 's/\..*//g')
if [ "$(echo "$STREAM0_HEIGHT > $SCREEN_HEIGHT" | bc -l)" -eq 1 ]; then
    STREAM0_HEIGHT=$SCREEN_HEIGHT
    STREAM0_WIDTH=$(echo "$STREAM0_HEIGHT * $STREAM_0_WIDTH_TO_HEIGHT_RATIO" | bc | sed 's/\..*//g')
fi
STREAM0_X=$SCREEN_LEFT
STREAM0_Y=$SCREEN_TOP

STREAM0_URL=$(get_url_by_index 0)
STREAM_GEOMETRIES+=("${STREAM0_URL} ${STREAM0_WIDTH}x${STREAM0_HEIGHT}+${STREAM0_X}+${STREAM0_Y}")

STREAM_1_WIDTH_TO_HEIGHT_RATIO=1.125
STREAM1_WIDTH=$(echo "0.2 * $SCREEN_WIDTH" | bc | sed 's/\..*//g')
STREAM1_HEIGHT=$(echo "$STREAM1_WIDTH * $STREAM_1_WIDTH_TO_HEIGHT_RATIO" | bc | sed 's/\..*//g')
if [ "$(echo "$STREAM1_HEIGHT > $SCREEN_HEIGHT" | bc -l)" -eq 1 ]; then
    STREAM1_HEIGHT=$SCREEN_HEIGHT
    STREAM1_WIDTH=$(echo "$STREAM1_HEIGHT * $STREAM_1_WIDTH_TO_HEIGHT_RATIO" | bc | sed 's/\..*//g')
fi
STREAM1_X=$(echo "$SCREEN_LEFT + $STREAM0_WIDTH + 455" | bc)
STREAM1_Y=$SCREEN_TOP

STREAM1_URL=$(get_url_by_index 1)
STREAM_GEOMETRIES+=("${STREAM1_URL} ${STREAM1_WIDTH}x${STREAM1_HEIGHT}+${STREAM1_X}+${STREAM1_Y}")

CONNECTABLE_STREAMS=()

# Add remaining streams (beyond the first 2) to connectable streams
TOTAL_STREAMS=$(get_stream_count)
for ((idx = 2; idx < TOTAL_STREAMS; idx++)); do
    URL=$(get_url_by_index "$idx")
    NAME=$(get_name_by_index "$idx")
    log "Adding stream to layout: '$NAME' ($(sanitize_url "$URL"))"
    CONNECTABLE_STREAMS+=("$URL")
done
NUM_CONNECTABLE_STREAMS=${#CONNECTABLE_STREAMS[@]}

ASPECT_RATIO=1.77777778  # Relación 16:9
if [ "$NUM_CONNECTABLE_STREAMS" -gt 0 ]; then
    CONNECTABLE_STREAM_WIDTH=$(echo "$SCREEN_WIDTH - $STREAM0_WIDTH" | bc | sed 's/\..*//g')
    CONNECTABLE_STREAM_HEIGHT=$(echo "$CONNECTABLE_STREAM_WIDTH / $ASPECT_RATIO" | bc | sed 's/\..*//g')
    if (( $(echo "$CONNECTABLE_STREAM_HEIGHT * $NUM_CONNECTABLE_STREAMS > $SCREEN_HEIGHT" | bc -l) )); then
        CONNECTABLE_STREAM_HEIGHT=$(echo "$SCREEN_HEIGHT / $NUM_CONNECTABLE_STREAMS" | bc | sed 's/\..*//g')
        CONNECTABLE_STREAM_WIDTH=$(echo "$CONNECTABLE_STREAM_HEIGHT * $ASPECT_RATIO" | bc | sed 's/\..*//g')
    fi

    log "Each of the $NUM_CONNECTABLE_STREAMS should have dimensions of $CONNECTABLE_STREAM_WIDTH x $CONNECTABLE_STREAM_HEIGHT"

    for i in $(seq 0 $((NUM_CONNECTABLE_STREAMS - 1))); do
        CONNECTABLE_STREAM_X=$(echo "$SCREEN_LEFT + $STREAM0_WIDTH" | bc)
        CONNECTABLE_STREAM_Y=$(echo "$SCREEN_TOP + $CONNECTABLE_STREAM_HEIGHT * $i" | bc | sed 's/\..*//g')

        STREAM_GEOMETRIES+=("${CONNECTABLE_STREAMS[i]} ${CONNECTABLE_STREAM_WIDTH}x${CONNECTABLE_STREAM_HEIGHT}+${CONNECTABLE_STREAM_X}+${CONNECTABLE_STREAM_Y}")
    done
fi

log "STREAMS DECLARED: ${#STREAM_CONNECTION_STREAMS[@]} CONNECTABLE: $NUM_CONNECTABLE_STREAMS"
export STREAM_GEOMETRIES
for geom in "${STREAM_GEOMETRIES[@]}"; do
    log Final stream and geometry: $(sanitize_url "${geom[0]}")" ${geom[1]}"
done
log STREAM_OPTS: "$STREAM_OPTS"

