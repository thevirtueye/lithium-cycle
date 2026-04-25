#!/usr/bin/env bash
#
# install.sh - Install lithium-cycle
#
# Run as root: sudo ./install.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "This installer must be run as root." >&2
    echo "Try: sudo ./install.sh" >&2
    exit 1
fi

# Verify systemd is present and is the active init.
if ! command -v systemctl >/dev/null 2>&1; then
    echo "ERROR: systemctl not found. This project requires systemd." >&2
    echo "Distros without systemd (Devuan, Artix, Void, Alpine) are not supported." >&2
    exit 1
fi
if [[ "$(ps -p 1 -o comm=)" != "systemd" ]]; then
    echo "ERROR: PID 1 is not systemd. This project requires systemd as init." >&2
    exit 1
fi

# Verify udev (or systemd-udev) is present.
if ! command -v udevadm >/dev/null 2>&1; then
    echo "ERROR: udevadm not found. This project requires udev." >&2
    exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BIN_PATH="/usr/local/bin/lithium-cycle"
CONFIG_DIR="/etc/lithium-cycle"
CONFIG_PATH="${CONFIG_DIR}/lithium-cycle.conf"
SERVICE_PATH="/etc/systemd/system/lithium-cycle.service"
TIMER_PATH="/etc/systemd/system/lithium-cycle.timer"
UDEV_PATH="/etc/udev/rules.d/99-lithium-cycle.rules"
STATE_DIR="/var/lib/lithium-cycle"

# --- Pre-flight check ---------------------------------------------------------

# Try to find a battery with a charge_control_end_threshold attribute.
found_battery=""
for bat in /sys/class/power_supply/BAT*; do
    if [[ -e "${bat}/charge_control_end_threshold" ]]; then
        found_battery=$(basename "$bat")
        break
    fi
done

if [[ -z "$found_battery" ]]; then
    cat >&2 <<'EOF'
ERROR: No battery with charge_control_end_threshold found.

This file is created by certain laptop kernel drivers when the firmware
exposes a charge threshold API. It looks like your laptop does not — at
least not with the modules currently loaded.

Things to check before giving up:

  1. Is this actually a laptop with a battery?
       ls /sys/class/power_supply/

  2. ThinkPad: ensure thinkpad_acpi is loaded.
       sudo modprobe thinkpad_acpi
       ls /sys/class/power_supply/BAT*/charge_control_end_threshold

  3. ASUS: ensure asus_wmi / asus_nb_wmi is loaded (recent ROG/ZenBook).

  4. IdeaPad / Lenovo non-Think: ensure ideapad_laptop is loaded.

  5. Huawei MateBook: ensure huawei_wmi is loaded.

  6. Some HP/Dell/Acer/MSI models do not expose this API to Linux at all.
     This project cannot help in that case — the firmware is the limit.

If you believe your laptop should be supported but is not, please open
an issue on the project tracker with the output of:
    uname -r
    lsmod
    ls /sys/class/power_supply/

EOF
    exit 1
fi

echo "Detected battery: $found_battery"

# --- Install files ------------------------------------------------------------

echo "Installing script to ${BIN_PATH}"
install -m 755 "${SRC_DIR}/src/lithium-cycle.sh" "$BIN_PATH"

echo "Installing config to ${CONFIG_PATH}"
install -d -m 755 "$CONFIG_DIR"
if [[ -e "$CONFIG_PATH" ]]; then
    echo "  (config already exists, leaving it untouched)"
else
    install -m 644 "${SRC_DIR}/config/lithium-cycle.conf" "$CONFIG_PATH"
    # If the detected battery is not BAT0, patch the config.
    if [[ "$found_battery" != "BAT0" ]]; then
        sed -i "s/^BATTERY=.*/BATTERY=${found_battery}/" "$CONFIG_PATH"
        echo "  (set BATTERY=${found_battery} in config)"
    fi
fi

echo "Installing systemd units"
install -m 644 "${SRC_DIR}/systemd/lithium-cycle.service" "$SERVICE_PATH"
install -m 644 "${SRC_DIR}/systemd/lithium-cycle.timer" "$TIMER_PATH"

echo "Installing udev rule"
install -m 644 "${SRC_DIR}/udev/99-lithium-cycle.rules" "$UDEV_PATH"

echo "Creating state directory"
install -d -m 755 "$STATE_DIR"

# --- Activate -----------------------------------------------------------------

echo "Reloading systemd and udev"
systemctl daemon-reload
udevadm control --reload-rules

echo "Enabling and starting timer"
systemctl enable --now lithium-cycle.timer

echo "Running initial evaluation"
systemctl start lithium-cycle.service

echo
echo "Done. Some useful commands:"
echo "  sudo lithium-cycle status            # human-readable status (read-only)"
echo "  systemctl status lithium-cycle.service lithium-cycle.timer"
echo "  journalctl -t lithium-cycle"
echo "  cat /sys/class/power_supply/${found_battery}/charge_control_end_threshold"
