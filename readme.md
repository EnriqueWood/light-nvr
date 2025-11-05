# light-nvr

A lightweight NVR solution for managing multiple camera streams using mpv on Linux. Built for efficiency and ease of use.
The software is specifically designed to be lightweight and optimized for Linux.

## Features

- **Custom layouts** - Save and restore window positions for your camera streams
- **Auto-reconnection** - Streams automatically reconnect when they drop
- **Credential security** - Stream URLs are never exposed in process listings (loaded via IPC)
- **Named streams** - Use meaningful names like "Front door" instead of IP addresses in logs or `ps` like commands
- **Recording** - Built-in recording with automatic segmentation and quota management
- **RAM buffering** - Optional RAM buffer for recordings to reduce disk wear
- **One connection per camera** - Display and recording share the same stream
- **Lightweight** - Minimal resource usage, runs on modest hardware

## Requirements

You'll need these tools installed:

- `mpv` - for playback and recording
- `ffmpeg` - includes ffprobe for duration calculation
- `socat` - IPC communication with mpv
- `xdotool` and `wmctrl` - window management
- `lsof` - process monitoring
- `jq` - JSON parsing
- `bash` - obviously

**Debian/Ubuntu:**
```bash
sudo apt update && sudo apt install mpv ffmpeg socat xdotool wmctrl lsof jq
```

**Arch/Manjaro:**
```bash
sudo pacman -S mpv ffmpeg socat xdotool wmctrl lsof jq
```

**Fedora:**
```bash
# Enable RPM Fusion for ffmpeg
sudo dnf install https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm
sudo dnf install mpv ffmpeg socat xdotool wmctrl lsof jq
```

**RHEL/CentOS:**
```bash
# Enable EPEL and RPM Fusion
sudo dnf install epel-release
sudo dnf install https://download1.rpmfusion.org/free/el/rpmfusion-free-release-$(rpm -E %rhel).noarch.rpm
sudo dnf install mpv ffmpeg socat xdotool wmctrl lsof jq
```

**openSUSE:**
```bash
# Add Packman repo for full ffmpeg codec support
sudo zypper ar -cfp 90 https://ftp.gwdg.de/pub/linux/misc/packman/suse/openSUSE_Tumbleweed/ packman
sudo zypper install mpv ffmpeg socat xdotool wmctrl lsof jq
```

## Quick Start

### 1. Clone and configure (Edit your stream URLs and settings)

```bash
git clone https://github.com/EnriqueWood/light-nvr
cd light-nvr
cp example-config.env config.env
vi config.env
```

### 2. Stream naming (recommended)

Add human-readable names to your streams by appending `###Name`:

```bash
export STREAM_CONNECTION_STREAMS=(
    "rtsp://user:pass@192.168.1.100:554/stream###Front door" \
    "rtsp://user:pass@192.168.1.101###Backyard" \
    "rtsp://192.168.1.102###Garage"
)
```

Why use names?
- Logs are much easier to read
- Credentials never show up in `ps aux` output
- If you don't provide a name, the IP address is used instead

**Important**: Stream names must be unique.

### 3. Create a layout

```bash
./layout.sh
```

Enter a name, specify how many windows you want, arrange them on screen, then press Enter to save. Layouts are stored in `~/.light-nvr/layouts/`.

To restore a saved layout:
```bash
./layout.sh <layout_name>
```

### 4. Start watching

```bash
./main.sh
```

The script will:
- Load your streams with the configured layout
- Monitor stream health and reconnect if needed
- Start recording if `RECORD_PATH` is set
- Manage disk quota if `RECORD_MAX_SIZE_MB` is set

Press Ctrl+C to stop everything gracefully.

## Configuration

### General settings

| Variable | Description | Default |
|----------|-------------|---------|
| `LAYOUT` | Layout file name from ~/.light-nvr/layouts/ | none |
| `LOGS_FOLDER` | Where to store logs | required |
| `LOG_RETENTION_DAYS` | Auto-delete logs older than N days (0=never) | 7 |
| `CONNECTION_HEALTHCHECK_SECONDS` | How often to check stream health | required |
| `STREAM_OPTS` | Extra mpv options | see example |
| `SCREEN_TOP` / `SCREEN_LEFT` | Screen offset for geometry calculations | 0 |
| `BASE_SCREEN_WIDTH` / `BASE_SCREEN_HEIGHT` | Base dimensions for auto layout | 1280x720 |
| `STREAM_CONNECTION_STREAMS` | Array of stream URLs (see example-config.env) | required |

### Recording settings

| Variable | Description | Default |
|----------|-------------|---------|
| `RECORD_PATH` | Where to save recordings (leave unset to disable) | none |
| `RECORD_SEGMENT_SECONDS` | Length of each recording file | 600 |
| `RECORD_MAX_SIZE_MB` | Total storage limit (oldest deleted first) | none |
| `RECORD_QUOTA_CHECK_SECONDS` | How often to check quota | 10 |
| `RECORD_USE_RAM_BUFFER` | Buffer to RAM before writing to disk | false |
| `RECORD_RAM_BUFFER_SIZE_MB` | RAM buffer size per stream | 512 |

Recording is disabled if `RECORD_PATH` isn't set. Quota management is disabled if `RECORD_MAX_SIZE_MB` isn't set.

RAM buffering helps reduce disk wear on systems with SSDs or limited I/O, but requires enough free RAM (at least 2GB recommended).

## Additional Tools

### gaps.sh

Analyze your recordings to find gaps and calculate total recorded time per camera:

```bash
./gaps.sh [path/to/recordings]  # Path optional, uses RECORD_PATH from config if not provided
```

This script:
- Scans each camera's recording folder
- Extracts duration from filename (format: `_length_XXXs.ts`) or probes the file if needed
- Detects gaps longer than 10 seconds between recordings
- Shows total recording time and average segment duration

Example output:
```
Processing /path/to/recordings/Front_door...
  Missing gap: 2025-11-05 14:30:45 → 2025-11-05 14:35:12 (4m 27s)
Total time recorded: 24h in 144 files (10m avg per file)
```

### Internal scripts

These run automatically, you don't need to call them:
- `spawn_monitor.sh` - Spawns mpv instances
- `watchdog.sh` - Monitors stream health
- `record_monitor.sh` - Handles recording segmentation
- `quota_monitor.sh` - Manages disk quota

## Notes

- No root privileges required
- If a layout has fewer windows than streams, remaining streams use default geometry
- Logs are automatically rotated based on `LOG_RETENTION_DAYS`
- The watchdog monitors for frozen streams (not just disconnections)

## Contributing

Found a bug? Have a feature idea? Contributions welcome!

- Open an issue: https://github.com/EnriqueWood/light-nvr/issues
- Submit a PR with your changes
- Star the repo if you find it useful

## License
Licenced under GNU GENERAL PUBLIC LICENSE v3.0 
Open source, distributed as-is. I take **no responsibility** for its usage. Use at your own risk.
