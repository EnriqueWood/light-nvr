#!/bin/bash

set -e

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    else
        echo "unknown"
    fi
}

OS=$(detect_os)

echo "Detected OS: $OS"
echo "Installing dependencies..."
echo

case "$OS" in
    ubuntu|debian|linuxmint|pop)
        sudo apt update
        sudo apt install -y mpv ffmpeg socat xdotool wmctrl lsof jq
        ;;
    arch|manjaro|endeavouros)
        sudo pacman -S --noconfirm mpv ffmpeg socat xdotool wmctrl lsof jq
        ;;
    fedora)
        echo "Enabling RPM Fusion repository for ffmpeg..."
        sudo dnf install -y https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm || true
        sudo dnf install -y mpv ffmpeg socat xdotool wmctrl lsof jq
        ;;
    rhel|centos|rocky|almalinux)
        echo "Enabling EPEL and RPM Fusion repositories..."
        sudo dnf install -y epel-release || true
        sudo dnf install -y https://download1.rpmfusion.org/free/el/rpmfusion-free-release-$(rpm -E %rhel).noarch.rpm || true
        sudo dnf install -y mpv ffmpeg socat xdotool wmctrl lsof jq
        ;;
    opensuse*|suse)
        echo "Adding Packman repository for full ffmpeg support..."
        sudo zypper ar -cfp 90 https://ftp.gwdg.de/pub/linux/misc/packman/suse/openSUSE_Tumbleweed/ packman || true
        sudo zypper --non-interactive install mpv ffmpeg socat xdotool wmctrl lsof jq
        ;;
    *)
        echo "Unsupported or unknown distribution: $OS"
        echo
        echo "Please install these packages manually:"
        echo "  mpv ffmpeg socat xdotool wmctrl lsof jq"
        exit 1
        ;;
esac

echo
echo "Dependencies installed successfully!"
echo
echo "Next steps:"
echo "  1. Copy example-config.env to config.env"
echo "  2. Edit config.env with your camera URLs"
echo "  3. Run ./main.sh to start"
