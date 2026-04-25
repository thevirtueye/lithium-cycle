#!/usr/bin/env bash
#
# lithium-cycle.sh - Monthly full-charge automation for laptop batteries
#
# Logic:
#   - Normal threshold: NORMAL_THRESHOLD (default 80)
#   - On day FULL_CHARGE_DAY of the month, if a full charge has not yet been
#     completed this month, raise threshold to FULL_THRESHOLD (default 100).
#   - The "full charge window" extends across days until capacity reaches 100%.
#   - When capacity reaches 100%, mark the month as completed and revert
#     threshold to normal.
#
# The script is idempotent: it can be invoked from udev events, a daily timer,
# or at service start, and it always converges on the correct state.

set -euo pipefail

# --- Configuration loading ----------------------------------------------------

CONFIG_FILE="${CHARGE_MANAGER_CONFIG:-/etc/lithium-cycle/lithium-cycle.conf}"
STATE_DIR="/var/lib/lithium-cycle"
STATE_FILE="${STATE_DIR}/state"
LOG_TAG="lithium-cycle"

# Defaults (overridable from config file)
BATTERY="BAT0"
NORMAL_THRESHOLD=80
FULL_THRESHOLD=100
FULL_CHARGE_DAY=1
# Capacity at which we consider "full charge reached". Some firmwares stop a
# hair below 100, so we accept >= this value as completion.
COMPLETION_CAPACITY=100

if [[ -r "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# --- Validation ---------------------------------------------------------------

# Fail loudly on any malformed config — we will be writing to /sys as root.
is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

if ! is_int "$NORMAL_THRESHOLD" || (( NORMAL_THRESHOLD < 1 || NORMAL_THRESHOLD > 100 )); then
    echo "Invalid NORMAL_THRESHOLD: $NORMAL_THRESHOLD" >&2
    exit 1
fi
if ! is_int "$FULL_THRESHOLD" || (( FULL_THRESHOLD < 1 || FULL_THRESHOLD > 100 )); then
    echo "Invalid FULL_THRESHOLD: $FULL_THRESHOLD" >&2
    exit 1
fi
if ! is_int "$FULL_CHARGE_DAY" || (( FULL_CHARGE_DAY < 1 || FULL_CHARGE_DAY > 28 )); then
    echo "Invalid FULL_CHARGE_DAY: $FULL_CHARGE_DAY (must be 1-28)" >&2
    exit 1
fi
if ! is_int "$COMPLETION_CAPACITY" || (( COMPLETION_CAPACITY < 1 || COMPLETION_CAPACITY > 100 )); then
    echo "Invalid COMPLETION_CAPACITY: $COMPLETION_CAPACITY" >&2
    exit 1
fi
# Battery name: must be alphanumeric only — it is interpolated into a /sys path.
if ! [[ "$BATTERY" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "Invalid BATTERY name: $BATTERY" >&2
    exit 1
fi

THRESHOLD_FILE="/sys/class/power_supply/${BATTERY}/charge_control_end_threshold"
CAPACITY_FILE="/sys/class/power_supply/${BATTERY}/capacity"

# The threshold file must exist either way. Writability is only required
# for evaluate(); the status subcommand is read-only, so we postpone the
# write check until we know which mode we are in.
if [[ ! -e "$THRESHOLD_FILE" ]]; then
    echo "Threshold file does not exist: $THRESHOLD_FILE" >&2
    echo "Your laptop may not support firmware-level charge thresholds." >&2
    exit 1
fi
if [[ ! -r "$CAPACITY_FILE" ]]; then
    echo "Capacity file not readable: $CAPACITY_FILE" >&2
    exit 1
fi

# --- Logging ------------------------------------------------------------------

log() {
    # Send to systemd journal when run under systemd, otherwise stderr.
    if command -v systemd-cat >/dev/null 2>&1 && [[ -n "${INVOCATION_ID:-}" ]]; then
        echo "$*" | systemd-cat -t "$LOG_TAG" -p info
    else
        echo "[$LOG_TAG] $*" >&2
    fi
}

# --- State helpers ------------------------------------------------------------

ensure_state_dir() {
    if [[ ! -d "$STATE_DIR" ]]; then
        mkdir -p "$STATE_DIR"
        chmod 755 "$STATE_DIR"
    fi
}

read_last_full_month() {
    if [[ -r "$STATE_FILE" ]]; then
        # Extract last_full_charge=YYYY-MM, ignore everything else.
        local value
        value=$(grep -E '^last_full_charge=' "$STATE_FILE" 2>/dev/null | tail -n1 | cut -d= -f2 || true)
        # Validate format strictly before returning.
        if [[ "$value" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
            echo "$value"
            return
        fi
    fi
    echo ""
}

write_last_full_month() {
    local month="$1"
    ensure_state_dir
    # Atomic write via temp + rename, so a crash mid-write cannot corrupt state.
    local tmp
    tmp=$(mktemp "${STATE_FILE}.XXXXXX")
    printf 'last_full_charge=%s\n' "$month" > "$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

# --- Hardware helpers ---------------------------------------------------------

get_capacity() {
    cat "$CAPACITY_FILE"
}

get_current_threshold() {
    cat "$THRESHOLD_FILE"
}

set_threshold() {
    local target="$1"
    local current
    current=$(get_current_threshold)
    if [[ "$current" == "$target" ]]; then
        return 0
    fi
    echo "$target" > "$THRESHOLD_FILE"
    log "Threshold changed: ${current} -> ${target}"
}

# --- Core logic ---------------------------------------------------------------

evaluate() {
    if [[ ! -w "$THRESHOLD_FILE" ]]; then
        echo "Threshold file not writable: $THRESHOLD_FILE" >&2
        echo "(This script must run as root for evaluate; use 'status' for read-only.)" >&2
        exit 1
    fi

    local today_month today_day capacity last_full_month
    today_month=$(date +%Y-%m)
    today_day=$(date +%-d)        # %-d strips leading zero
    capacity=$(get_capacity)
    last_full_month=$(read_last_full_month)

    # Has a full charge already been completed this month?
    if [[ "$last_full_month" == "$today_month" ]]; then
        # Yes — stay in normal mode regardless of day.
        set_threshold "$NORMAL_THRESHOLD"
        return 0
    fi

    # No full charge yet this month. Are we in or past the target day?
    if (( today_day >= FULL_CHARGE_DAY )); then
        # Full-charge window is open. If we have already reached completion
        # capacity, mark the month done and revert. Otherwise raise threshold.
        if (( capacity >= COMPLETION_CAPACITY )); then
            write_last_full_month "$today_month"
            log "Full charge completed for ${today_month} (capacity=${capacity}%)"
            set_threshold "$NORMAL_THRESHOLD"
        else
            set_threshold "$FULL_THRESHOLD"
        fi
    else
        # Before the target day this month — normal mode.
        set_threshold "$NORMAL_THRESHOLD"
    fi
}

# --- Status sub-command -------------------------------------------------------
# Print a human-readable summary of the current state. Read-only: does not
# modify any file. Useful for users to verify the system is healthy.

show_status() {
    local cap thr state today_month today_day last_full_month
    cap=$(get_capacity)
    thr=$(get_current_threshold)
    today_month=$(date +%Y-%m)
    today_day=$(date +%-d)
    last_full_month=$(read_last_full_month)
    if [[ -n "$last_full_month" ]]; then
        state="$last_full_month"
    else
        state="(no completion recorded yet)"
    fi

    cat <<EOF
lithium-cycle status
─────────────────────
Battery device:         $BATTERY
Current capacity:       ${cap}%
Current threshold:      ${thr}%
Today:                  ${today_month} (day ${today_day})
Full charge day:        ${FULL_CHARGE_DAY}
Last full charge:       ${state}
Normal threshold:       ${NORMAL_THRESHOLD}%
Full threshold:         ${FULL_THRESHOLD}%
Completion capacity:    ${COMPLETION_CAPACITY}%

Mode this month:        $(
    if [[ "$last_full_month" == "$today_month" ]]; then
        echo "completed (threshold should be ${NORMAL_THRESHOLD}%)"
    else
        echo "open window (threshold should be ${FULL_THRESHOLD}%)"
    fi
)

Systemd:
$(systemctl is-active lithium-cycle.timer 2>/dev/null \
    | sed 's/^/  timer:    /')
$(systemctl is-enabled lithium-cycle.timer 2>/dev/null \
    | sed 's/^/  timer:    enabled=/')

Next scheduled run:
$(systemctl list-timers lithium-cycle.timer --no-pager 2>/dev/null \
    | grep -E '^[A-Z][a-z]{2} ' | head -n1 | awk '{print "  " $1, $2, $3, $4}')
EOF
}

# --- Entry point --------------------------------------------------------------

case "${1:-}" in
    status)
        show_status
        ;;
    "")
        evaluate
        ;;
    *)
        echo "Usage: $0 [status]" >&2
        echo "  (no args)  Run an evaluation pass (used by systemd)." >&2
        echo "  status     Show a human-readable status summary." >&2
        exit 2
        ;;
esac
