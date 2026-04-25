#!/usr/bin/env bash
#
# test-dryrun.sh - Run lithium-cycle.sh against a fake /sys sandbox.
#
# This does NOT touch your real battery, /sys, /var/lib, or systemd.
# It builds a temporary directory tree that mimics /sys/class/power_supply,
# patches lithium-cycle.sh on the fly to point at it, and replays a long
# list of scenarios. It also lets you fake "today" via the FAKE_DATE env var.
#
# Usage:
#   ./tests/test-dryrun.sh           # run all scenarios
#   ./tests/test-dryrun.sh -v        # verbose (show every state change)

set -euo pipefail

VERBOSE=0
[[ "${1:-}" == "-v" ]] && VERBOSE=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORIG_SCRIPT="${REPO_ROOT}/src/lithium-cycle.sh"

if [[ ! -f "$ORIG_SCRIPT" ]]; then
    echo "Cannot find $ORIG_SCRIPT" >&2
    exit 1
fi

# --- Build sandbox ------------------------------------------------------------

SANDBOX=$(mktemp -d -t charge-mgr-test.XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT

FAKE_SYS="${SANDBOX}/sys/class/power_supply/BAT0"
FAKE_STATE_DIR="${SANDBOX}/var/lib/lithium-cycle"
FAKE_CONFIG="${SANDBOX}/lithium-cycle.conf"
PATCHED_SCRIPT="${SANDBOX}/lithium-cycle.sh"

mkdir -p "$FAKE_SYS" "$FAKE_STATE_DIR"
echo 80  > "$FAKE_SYS/charge_control_end_threshold"
echo 50  > "$FAKE_SYS/capacity"

cat > "$FAKE_CONFIG" <<EOF
BATTERY=BAT0
NORMAL_THRESHOLD=80
FULL_THRESHOLD=100
FULL_CHARGE_DAY=1
COMPLETION_CAPACITY=100
EOF

# Patch the script:
#   - redirect /sys/class/power_supply -> sandbox
#   - redirect /var/lib/lithium-cycle -> sandbox
#   - redirect date -> a wrapper that honors FAKE_DATE
# shellcheck disable=SC2016  # single quotes are intentional: we substitute literal text
sed \
    -e "s|/sys/class/power_supply|${SANDBOX}/sys/class/power_supply|g" \
    -e "s|/var/lib/lithium-cycle|${FAKE_STATE_DIR}|g" \
    -e 's|today_month=$(date |today_month=$(fakedate |' \
    -e 's|today_day=$(date |today_day=$(fakedate |' \
    "$ORIG_SCRIPT" > "$PATCHED_SCRIPT"

# Inject a fakedate function at the top (after the shebang).
# shellcheck disable=SC2016
sed -i '1a\
fakedate() {\
    if [[ -n "${FAKE_DATE:-}" ]]; then\
        date -d "$FAKE_DATE" "$@"\
    else\
        date "$@"\
    fi\
}' "$PATCHED_SCRIPT"

chmod +x "$PATCHED_SCRIPT"

# --- Test helpers -------------------------------------------------------------

PASS=0
FAIL=0
FAILED_CASES=()

set_capacity()  { echo "$1" > "$FAKE_SYS/capacity"; }
set_threshold() { echo "$1" > "$FAKE_SYS/charge_control_end_threshold"; }
get_threshold() { cat "$FAKE_SYS/charge_control_end_threshold"; }
get_state() {
    if [[ -r "${FAKE_STATE_DIR}/state" ]]; then
        grep -E '^last_full_charge=' "${FAKE_STATE_DIR}/state" | cut -d= -f2
    else
        echo ""
    fi
}
set_state() {
    if [[ -z "$1" ]]; then
        rm -f "${FAKE_STATE_DIR}/state"
    else
        echo "last_full_charge=$1" > "${FAKE_STATE_DIR}/state"
    fi
}

# run_case <name> <fake_date> <initial_capacity> <initial_threshold>
#          <initial_state> <expected_threshold> <expected_state>
run_case() {
    local name="$1" fake_date="$2" cap="$3" thr="$4" state="$5"
    local exp_thr="$6" exp_state="$7"

    set_capacity  "$cap"
    set_threshold "$thr"
    set_state     "$state"

    FAKE_DATE="$fake_date" CHARGE_MANAGER_CONFIG="$FAKE_CONFIG" \
        bash "$PATCHED_SCRIPT" 2>/dev/null

    local got_thr got_state
    got_thr=$(get_threshold)
    got_state=$(get_state)

    if [[ "$got_thr" == "$exp_thr" && "$got_state" == "$exp_state" ]]; then
        PASS=$((PASS+1))
        if (( VERBOSE )); then
            printf '  \033[32mPASS\033[0m %s\n' "$name"
            printf '       date=%s cap=%s start{thr=%s state=%s} -> {thr=%s state=%s}\n' \
                "$fake_date" "$cap" "$thr" "$state" "$got_thr" "$got_state"
        else
            printf '  \033[32m.\033[0m'
        fi
    else
        FAIL=$((FAIL+1))
        FAILED_CASES+=("$name")
        printf '\n  \033[31mFAIL\033[0m %s\n' "$name"
        printf '       date=%s capacity=%s\n' "$fake_date" "$cap"
        printf '       initial:  threshold=%s  state=%s\n' "$thr" "$state"
        printf '       expected: threshold=%s  state=%s\n' "$exp_thr" "$exp_state"
        printf '       got:      threshold=%s  state=%s\n' "$got_thr" "$got_state"
    fi
}

section() {
    if (( ! VERBOSE )); then echo; fi
    echo
    echo "── $1 ──"
}

# --- Scenarios ----------------------------------------------------------------
#
# Columns:
#   name | fake_date | start_cap | start_thr | start_state | expect_thr | expect_state

section "Mid-month, current month NOT completed -> window stays open"
# Per spec: if a month is not marked as completed, the window is open all month.
# A fresh install at mid-month, or simply having missed the previous day,
# results in threshold=100 until 100% is reached.
run_case "Mar 15, last full was Feb, March not done yet -> 100" \
    "2026-03-15" 65 80 "2026-02" 100 "2026-02"
run_case "Mar 15, threshold already 100, March still open" \
    "2026-03-15" 65 100 "2026-02" 100 "2026-02"
run_case "Mar 15, fresh install (no state) -> open window, 100" \
    "2026-03-15" 65 80 "" 100 ""
run_case "Mar 15, fresh install, already at 100% -> mark March done, 80" \
    "2026-03-15" 100 80 "" 80 "2026-03"

section "Mid-month, current month ALREADY completed -> stay at 80"
run_case "Mar 15, March already done, normal day" \
    "2026-03-15" 65 80 "2026-03" 80 "2026-03"
run_case "Mar 15, March done, threshold drift -> revert to 80" \
    "2026-03-15" 65 100 "2026-03" 80 "2026-03"

section "Target day, full charge NOT yet done this month"
run_case "Apr 1 morning, 78%, just plugged in" \
    "2026-04-01" 78 80 "2026-03" 100 "2026-03"
run_case "Apr 1, 92% mid-charge, re-trigger" \
    "2026-04-01" 92 100 "2026-03" 100 "2026-03"
run_case "Apr 1, 100% reached -> mark month done, revert to 80" \
    "2026-04-01" 100 100 "2026-03" 80 "2026-04"
run_case "Apr 1, fresh install (no state), 70%" \
    "2026-04-01" 70 80 "" 100 ""
run_case "Apr 1, fresh install, already at 100%" \
    "2026-04-01" 100 80 "" 80 "2026-04"

section "Target day, full charge ALREADY done this month"
run_case "Apr 1, 100% (still plugged after completion)" \
    "2026-04-01" 100 80 "2026-04" 80 "2026-04"
run_case "Apr 1, 95% (unplugged, drifting down)" \
    "2026-04-01" 95 80 "2026-04" 80 "2026-04"
run_case "Apr 1, threshold somehow at 100, state says done -> revert" \
    "2026-04-01" 95 100 "2026-04" 80 "2026-04"

section "Day 1 missed: laptop off, picks up day 2+"
run_case "Apr 2, 70%, last full was March" \
    "2026-04-02" 70 80 "2026-03" 100 "2026-03"
run_case "Apr 5, 85%, still chasing the April full" \
    "2026-04-05" 85 100 "2026-03" 100 "2026-03"
run_case "Apr 5, 100% finally reached" \
    "2026-04-05" 100 100 "2026-03" 80 "2026-04"
run_case "Apr 28, 100%, still no April full ever done -> mark done now" \
    "2026-04-28" 100 80 "2026-03" 80 "2026-04"

section "Month rollover after a completed full charge"
run_case "Apr 30, 80%, April is done" \
    "2026-04-30" 80 80 "2026-04" 80 "2026-04"
run_case "May 1 00:01 timer, 78%, plugged in" \
    "2026-05-01" 78 80 "2026-04" 100 "2026-04"
run_case "May 1, 100% reached" \
    "2026-05-01" 100 100 "2026-04" 80 "2026-05"

section "Edge: capacity exactly at COMPLETION_CAPACITY"
run_case "Apr 1, capacity 100 exactly, not yet done" \
    "2026-04-01" 100 80 "2026-03" 80 "2026-04"

section "Edge: empty / corrupt state file"
run_case "Apr 1, empty state value" \
    "2026-04-01" 70 80 "" 100 ""
# Manual setup for corrupt state
set_state "2026-04"
echo "garbage line" >> "${FAKE_STATE_DIR}/state"
echo 70 > "$FAKE_SYS/capacity"
echo 80 > "$FAKE_SYS/charge_control_end_threshold"
FAKE_DATE="2026-04-15" CHARGE_MANAGER_CONFIG="$FAKE_CONFIG" \
    bash "$PATCHED_SCRIPT" 2>/dev/null
got=$(get_threshold)
if [[ "$got" == "80" ]]; then
    PASS=$((PASS+1))
    (( VERBOSE )) && echo "  PASS Apr 15, state file with garbage trailing line still parsed" \
                  || printf '  \033[32m.\033[0m'
else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("Apr 15, garbage trailing line")
    printf '\n  \033[31mFAIL\033[0m Apr 15, garbage trailing line: expected threshold=80, got %s\n' "$got"
fi

section "Boundary: cross-month transitions"
run_case "Feb 28, Feb not done since Jan, window still open -> 100" \
    "2026-02-28" 70 80 "2026-01" 100 "2026-01"
run_case "Feb 28, Feb already done -> 80" \
    "2026-02-28" 70 80 "2026-02" 80 "2026-02"
run_case "Mar 1 transitions to full mode (Feb completed)" \
    "2026-03-01" 70 80 "2026-02" 100 "2026-02"

# --- Summary ------------------------------------------------------------------

echo
echo
echo "──────────────────────────────────────"
printf "Passed: \033[32m%d\033[0m   Failed: " "$PASS"
if (( FAIL > 0 )); then
    printf '\033[31m%d\033[0m\n' "$FAIL"
    echo "Failed cases:"
    for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
    exit 1
else
    printf '\033[32m%d\033[0m\n' "$FAIL"
    echo "All scenarios passed."
fi
