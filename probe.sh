#!/bin/bash

URL_RTSP="$1"
TIMEOUT="${2:-10}"
DEFAULT_RESOLUTION="1920x1080"
OUTPUT=$(timeout "$TIMEOUT" ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$URL_RTSP" 2>&1)
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    WIDTH=$(echo "$OUTPUT" | cut -d'x' -f1)
    HEIGHT=$(echo "$OUTPUT" | cut -d'x' -f2)
    if [[ -n "$WIDTH" && -n "$HEIGHT" ]]; then
        echo "${WIDTH}x${HEIGHT}"
        exit 0
    else
        exit 1
    fi
else
    if curl -I "$URL_RTSP" 2>/dev/null; then
            echo "$DEFAULT_RESOLUTION"
            exit 0
        else
            exit 1
        fi
fi