#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYOUTS_DIR="$HOME/.light-nvr/layouts"

declare -a mpv_pids=()
declare -a sockets=()

cleanup() {
    for pid in "${mpv_pids[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
        fi
    done

    for socket in "${sockets[@]}"; do
        if [[ -e "$socket" ]]; then
            rm -f "$socket"
        fi
    done
}

trap cleanup EXIT

require_commands() {
    for cmd in "$@"; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "Error: $cmd is not installed." >&2
            exit 1
        fi
    done
}

create_layouts_dir() {
    if [[ ! -d "$LAYOUTS_DIR" ]]; then
        mkdir -p "$LAYOUTS_DIR"
    fi
}

prompt_layout_name() {
    create_layouts_dir
    while true; do
        read -rp "Enter the layout name: " layout_name
        layout_file="$LAYOUTS_DIR/${layout_name// /_}.layout"
        if [[ -e "$layout_file" ]]; then
            read -rp "File '$layout_file' already exists. Overwrite? (y/n): " choice
            case "$choice" in
                y|Y ) break ;;
                n|N ) continue ;;
                * ) echo "Please enter 'y' or 'n'." ;;
            esac
        else
            break
        fi
    done
    echo "$layout_file"
}

prompt_window_count() {
    while true; do
        read -rp "How many windows will it have?: " count
        if [[ "$count" =~ ^[1-9][0-9]*$ ]]; then
            echo "$count"
            return
        else
            echo "Please enter a positive integer." >&2
        fi
    done
}

generate_socket() {
    mktemp --tmpdir mpvsocket_XXXXXX
}

launch_mpv_instances() {
    local count=$1
    for ((i = 1; i <= count; i++)); do
        local socket
        socket=$(generate_socket)
        sockets+=("$socket")
        mpv --no-border --idle --input-ipc-server="$socket" &
        mpv_pids+=("$!")
        sleep 0.5
    done
}

display_stream_numbers() {
    for ((i = 0; i < ${#sockets[@]}; i++)); do
        local socket=${sockets[$i]}
        local stream_number=$((i + 1))
        echo '{ "command": ["show-text", "Stream '"$stream_number"'", 30000000] }' | socat - "$socket" &
    done
}

capture_window_geometries() {
    local layout_file=$1
    echo "Capturing geometries in file '$layout_file'"
#    > "$layout_file"
    for socket in "${sockets[@]}"; do
        local mpv_pid
        mpv_pid=$(lsof -t "$socket" 2>/dev/null) || {
            echo "Could not retrieve PID for socket $socket." >&2
            continue
        }
        local window_id
        window_id=$(xdotool search --pid "$mpv_pid" | head -n 1) || {
            echo "Could not retrieve window ID for PID $mpv_pid." >&2
            continue
        }
        eval "$(xdotool getwindowgeometry --shell "$window_id")" || {
            echo "Could not retrieve geometry for window ID $window_id." >&2
            continue
        }
        echo "${WIDTH}x${HEIGHT}+${X}+${Y}" >> "$layout_file"
    done
}

apply_layout() {
    local layout_file=$1
    while IFS= read -r geometry; do
        [[ -z "$geometry" ]] && continue
        local socket
        socket=$(generate_socket)
        sockets+=("$socket")
        mpv --idle --no-border --geometry="$geometry" --input-ipc-server="$socket" &
        mpv_pids+=("$!")
        sleep 0.5
    done < "$layout_file"
}

open_streams_from_config() {
    if declare -p STREAM_CONNECTION_STREAMS &> /dev/null && [[ ${#STREAM_CONNECTION_STREAMS[@]} -gt 0 ]]; then
        echo "Opening ${#STREAM_CONNECTION_STREAMS[@]} streams from config.env..."
        local stream_count=0
        for stream_url in "${STREAM_CONNECTION_STREAMS[@]}"; do
            stream_count=$((stream_count + 1))
            local socket
            socket=$(generate_socket)
            sockets+=("$socket")
            mpv "$stream_url" --loop-playlist=force --no-border --input-ipc-server="$socket" &> /dev/null &
            mpv_pids+=("$!")
            echo "Opened stream $stream_count"
            sleep 0.5
        done
    else
     echo "STREAM_CONNECTION_STREAMS is not defined"
    fi
}

main() {
    require_commands lsof xdotool socat mpv mktemp

    create_layouts_dir

    if [[ $# -eq 1 && -f "$LAYOUTS_DIR/$1.layout" ]]; then
        local layout_file="$LAYOUTS_DIR/$1.layout"
        echo "Applying layout from $layout_file..."
        apply_layout "$layout_file"
        display_stream_numbers
        echo "Adjust the mpv windows as desired and press Enter when done."
        read -r
        read -rp "Enter a name for the new layout or press Enter to overwrite '$layout_file': " new_layout_name
        if [[ -n "$new_layout_name" ]]; then
            layout_file="$LAYOUTS_DIR/${new_layout_name// /_}.layout"
            if [[ -e "$layout_file" ]]; then
                read -rp "File '$layout_file' already exists. Overwrite? (y/n): " choice
                case "$choice" in
                    y|Y ) ;;
                    n|N ) echo "Layout not saved. Exiting."; exit 0 ;;
                    * ) echo "Invalid choice. Exiting."; exit 1 ;;
                esac
            fi
        fi
        capture_window_geometries "$layout_file"
        echo "Layout saved successfully in $layout_file."
    else
        local layout_file
        layout_file=$(prompt_layout_name)
        local window_count
        local read_from_config_env
        read_from_config_env="n"
        [[ -f "$SCRIPT_DIR/config.env" ]] && read -rp "Try to match streams from config.env file? (y/n): " read_from_config_env
        if [[ "$read_from_config_env" == "Y" || "$read_from_config_env" == "y" ]]; then
                echo "Reading config.env file..."
                source "$SCRIPT_DIR/config.env"
                echo "Launching streams..."
                open_streams_from_config
        else
                window_count=$(prompt_window_count)
                echo "Launching $window_count mpv players..."
                launch_mpv_instances "$window_count"
        fi
        display_stream_numbers
        echo "Arrange the mpv windows as desired and press Enter when done."
        read -r
        capture_window_geometries "$layout_file"
        echo "Layout saved successfully in $layout_file."
    fi
}

main "$@"
