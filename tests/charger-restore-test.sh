#!/bin/bash
# Regression tests for the 2026-10-02 "plugged in but drawing nothing" failure.
#
# Three defects are covered here:
#   1. the cleanup skipped its charger restore whenever VBUS was already absent,
#      stranding the next plug-in at a 5 V / 0 A operating point;
#   2. nothing re-asserted sane charger values when the policy sat idle with a
#      dead Qualcomm path, so the device drained on the cable until a human
#      noticed;
#   3. the PPS handshake latched a fault on a transient, costing cable cycles.
#
# Everything runs against a fake power-supply tree, so no real hardware and no
# root privileges are involved.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
POLICY="$REPO/payload/bin/armada-pocketevo-charge-policy"
CLEANUP="$REPO/payload/bin/armada-pocketevo-charge-cleanup"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

passed=0
failed=0

ok()
{
	printf '  ok    %s\n' "$1"
	passed=$((passed + 1))
}

no()
{
	printf '  FAIL  %s\n' "$1"
	failed=$((failed + 1))
}

section()
{
	printf '== %s\n' "$1"
}

check_eq()
{
	if test "$2" = "$3"; then
		ok "$1"
	else
		no "$1 (expected '$3', got '$2')"
	fi
}

check_contains()
{
	case "$2" in
	*"$3"*) ok "$1" ;;
	*) no "$1 (expected to contain '$3', got: $2)" ;;
	esac
}

# Build a fake power-supply tree.
#   usb_online   value of qcom-battmgr-usb/online
#   usb_i        value of qcom-battmgr-usb/current_now (uA)
#   bat_i        value of battery/current_now (uA)
#   bat_status   value of battery/status
new_tree()
{
	rm -rf "$TMP/ps" "$TMP/state"
	mkdir -p "$TMP/ps/qcom-battmgr-usb"
	mkdir -p "$TMP/ps/battery"
	mkdir -p "$TMP/ps/hl7139-5f"
	mkdir -p "$TMP/ps/hl7139-5e"
	mkdir -p "$TMP/state"

	printf '%s\n' "$1" > "$TMP/ps/qcom-battmgr-usb/online"
	printf '%s\n' "$2" > "$TMP/ps/qcom-battmgr-usb/current_now"
	printf '%s\n' "$3" > "$TMP/ps/battery/current_now"
	printf '%s\n' "$4" > "$TMP/ps/battery/status"
	# No PPS advertised: keeps eligible() false so the policy reaches the idle
	# branch, which is where the repair runs.
	printf 'Unknown SDP\n' > "$TMP/ps/qcom-battmgr-usb/usb_type"
	printf '59\n' > "$TMP/ps/battery/capacity"
	printf '3900000\n' > "$TMP/ps/battery/voltage_now"
	printf '250\n' > "$TMP/ps/battery/temp"
	printf '0\n' > "$TMP/ps/hl7139-5f/online"
	printf '0\n' > "$TMP/ps/hl7139-5e/online"
	printf 'Good\n' > "$TMP/ps/hl7139-5f/health"
	printf 'Good\n' > "$TMP/ps/hl7139-5e/health"
	# Record what the policy / cleanup write.
	: > "$TMP/ps/qcom-battmgr-usb/voltage_now"
	: > "$TMP/ps/qcom-battmgr-usb/input_current_limit"
}

run_cleanup()
{
	ARMADA_POWER_SUPPLY_ROOT="$TMP/ps" \
	ARMADA_CHARGE_MASTER="$TMP/ps/hl7139-5f" \
	ARMADA_CHARGE_SLAVE="$TMP/ps/hl7139-5e" \
	ARMADA_CHARGE_STATE_DIR="$TMP/state" \
	ARMADA_CHARGE_SLEEP_CMD=true \
		"$CLEANUP" > "$TMP/out.txt" 2>&1
	printf '%s' "$?"
}

run_policy_idle()
{
	# A no-op cleanup keeps the initial pass (line ~418) from writing the same
	# values, so anything on disk afterwards can only have come from
	# repair_stock_charger.
	ARMADA_POWER_SUPPLY_ROOT="$TMP/ps" \
	ARMADA_CHARGE_MASTER="$TMP/ps/hl7139-5f" \
	ARMADA_CHARGE_SLAVE="$TMP/ps/hl7139-5e" \
	ARMADA_CHARGE_CLEANUP=/bin/true \
	ARMADA_CHARGE_STATE_DIR="$TMP/state" \
	ARMADA_CHARGE_SLEEP_CMD=true \
	ARMADA_CHARGE_MAX_IDLE_LOOPS=1 \
		"$POLICY" > "$TMP/policy.txt" 2>&1
	printf '%s' "$?"
}

# ---------------------------------------------------------------------------
section 'cleanup: cable pulled mid-session (VBUS already absent) must still restore'
new_tree 0 0 -900000 Discharging
rc=$(run_cleanup)
check_eq 'cleanup exits 0' "$rc" 0
check_eq 'PPS request restored to 9600000uV' \
	"$(cat "$TMP/ps/qcom-battmgr-usb/voltage_now")" 9600000
check_eq 'input limit released from the 13mA handoff' \
	"$(cat "$TMP/ps/qcom-battmgr-usb/input_current_limit")" 3000000
check_contains 'logs the offline restore' "$(cat "$TMP/out.txt")" 'USB offline (charger restore written)'
if test -e "$TMP/state/fault"; then
	no 'offline restore must not latch a fault'
else
	ok 'offline restore does not latch a fault'
fi

# ---------------------------------------------------------------------------
section 'cleanup: normal case (VBUS present) is unchanged'
new_tree 1 0 -900000 Discharging
rc=$(run_cleanup)
check_eq 'cleanup exits 0' "$rc" 0
check_eq 'PPS request restored to 9600000uV' \
	"$(cat "$TMP/ps/qcom-battmgr-usb/voltage_now")" 9600000
check_eq 'input limit restored to 3000000uA' \
	"$(cat "$TMP/ps/qcom-battmgr-usb/input_current_limit")" 3000000
check_contains 'logs the normal restore' "$(cat "$TMP/out.txt")" 'Qualcomm charger restored'

# ---------------------------------------------------------------------------
section 'cleanup: VBUS present and the restore is refused must latch a fault'
new_tree 1 0 -900000 Discharging
chmod 0444 "$TMP/ps/qcom-battmgr-usb/input_current_limit"
rc=$(run_cleanup)
chmod 0644 "$TMP/ps/qcom-battmgr-usb/input_current_limit"
check_eq 'cleanup exits 1' "$rc" 1
check_contains 'latches a fault' "$(cat "$TMP/state/fault" 2>/dev/null)" 'could not be restored'

# ---------------------------------------------------------------------------
section 'policy idle with an online charger drawing nothing: repair fires'
new_tree 1 0 -950000 Discharging
rc=$(run_policy_idle)
check_eq 'policy exits 0' "$rc" 0
check_eq 'repair re-asserts 9600000uV' \
	"$(cat "$TMP/ps/qcom-battmgr-usb/voltage_now")" 9600000
check_eq 'repair re-asserts 3000000uA' \
	"$(cat "$TMP/ps/qcom-battmgr-usb/input_current_limit")" 3000000
check_contains 'logs the repair' "$(cat "$TMP/policy.txt")" 'charger repair:'
check_contains 'names both offending currents' "$(cat "$TMP/policy.txt")" 'battery=-950000uA'
check_eq 'repair is rate-limited' "$(cat "$TMP/state/last-repair" 2>/dev/null)" \
	"$(cut -d' ' -f1 /proc/uptime | cut -d. -f1)"

# ---------------------------------------------------------------------------
section 'policy idle with a healthy charger: repair must stay out of the way'
new_tree 1 3000000 2100000 Charging
rc=$(run_policy_idle)
check_eq 'policy exits 0' "$rc" 0
check_eq 'leaves the PPS request alone' \
	"$(cat "$TMP/ps/qcom-battmgr-usb/voltage_now")" ''
check_eq 'leaves the input limit alone' \
	"$(cat "$TMP/ps/qcom-battmgr-usb/input_current_limit")" ''
if test -r "$TMP/state/last-repair"; then
	no 'a healthy charger must not start the rate-limit clock'
else
	ok 'a healthy charger does not start the rate-limit clock'
fi

# ---------------------------------------------------------------------------
section 'policy idle with VBUS absent: repair must not fire'
new_tree 0 0 -950000 Discharging
rc=$(run_policy_idle)
check_eq 'policy exits 0' "$rc" 0
check_eq 'leaves the PPS request alone with no cable' \
	"$(cat "$TMP/ps/qcom-battmgr-usb/voltage_now")" ''
check_eq 'leaves the input limit alone with no cable' \
	"$(cat "$TMP/ps/qcom-battmgr-usb/input_current_limit")" ''

# ---------------------------------------------------------------------------
section 'policy idle but a pump is still enabled: repair must not touch the charger'
new_tree 1 0 -950000 Discharging
printf '1\n' > "$TMP/ps/hl7139-5f/online"
rc=$(run_policy_idle)
check_eq 'policy exits 0' "$rc" 0
check_eq 'leaves the PPS request alone while a pump is live' \
	"$(cat "$TMP/ps/qcom-battmgr-usb/voltage_now")" ''

# ---------------------------------------------------------------------------
section 'the PPS handshake retries instead of latching on a transient'
new_tree 1 0 -950000 Discharging
# The source is parked at the cleanup's 9.6 V while 8.8 V is requested -- the
# exact 2026-10-02 stall -- so the widened window must accept it. 8.8 V + 800 mV
# is the ceiling; anything past it still has to fault.
printf '8800000\n' > "$TMP/ps/qcom-battmgr-usb/voltage_now"
grep -q 'target + 800000' "$POLICY" \
	&& ok 'accepts a source parked up to 800mV above the request' \
	|| no 'missing the widened acceptance window'
# And the hard ceiling must still be enforced lower than the 10.0 V pump limit.
grep -qE 'gt 9000000; then target=9000000' "$POLICY" \
	&& ok 'keeps the request below the 10.0V pump enable ceiling' \
	|| no 'lost the 9.0V request ceiling'

printf '\n%d passed, %d failed\n' "$passed" "$failed"
test "$failed" -eq 0
