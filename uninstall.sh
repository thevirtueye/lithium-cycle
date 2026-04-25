#!/usr/bin/env bash
#
# uninstall.sh - Remove lithium-cycle
#
# Run as root: sudo ./uninstall.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "This uninstaller must be run as root." >&2
    echo "Try: sudo ./uninstall.sh" >&2
    exit 1
fi

BIN_PATH="/usr/local/bin/lithium-cycle"
CONFIG_DIR="/etc/lithium-cycle"
SERVICE_PATH="/etc/systemd/system/lithium-cycle.service"
TIMER_PATH="/etc/systemd/system/lithium-cycle.timer"
UDEV_PATH="/etc/udev/rules.d/99-lithium-cycle.rules"
STATE_DIR="/var/lib/lithium-cycle"

echo "Stopping and disabling units"
systemctl disable --now lithium-cycle.timer 2>/dev/null || true
systemctl stop lithium-cycle.service 2>/dev/null || true

echo "Removing files"
rm -f "$BIN_PATH" "$SERVICE_PATH" "$TIMER_PATH" "$UDEV_PATH"

echo "Reloading systemd and udev"
systemctl daemon-reload
udevadm control --reload-rules

# Optional cleanup — ask before nuking config and state.
read -r -p "Remove config directory ${CONFIG_DIR}? [y/N] " ans
if [[ "$ans" =~ ^[Yy]$ ]]; then
    rm -rf "$CONFIG_DIR"
fi

read -r -p "Remove state directory ${STATE_DIR}? [y/N] " ans
if [[ "$ans" =~ ^[Yy]$ ]]; then
    rm -rf "$STATE_DIR"
fi

echo
echo "Uninstalled. Note: the kernel will keep whatever charge threshold value"
echo "was last written until reboot or another tool changes it."
