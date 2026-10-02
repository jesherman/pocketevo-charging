#!/bin/bash
# Full simulated direct-charge sessions, driven through the policy's own sample
# hook, against a fake power-supply tree. No root, no device, no hardware.
#
# charger-restore-test.sh covers the cleanup and the policy's *idle* path. This
# file drives whole sessions through direct_session()'s watch loop, which is the
# only way to exercise the guards that end a session:
#
#   * the no-delivery guard actually firing after 30 s of zero current;
#   * a shorter stall NOT ending the session;
#   * the endpoint guard ending a session cleanly, without latching;
#   * the VIN-headroom regulator holding the rail under the 10.5 V ceiling --
#     the 2026-10-02 integrator-windup bug that killed a healthy session at
#     SOC 88% with a latched "unplug the charger" fault.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
POLICY="$REPO/payload/bin/armada-pocketevo-charge-policy"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

passed=0
failed=0
ok() { printf '  ok    %s\n' "$1"; passed=$((passed + 1)); }
no() { printf '  FAIL  %s\n' "$1"; failed=$((failed + 1)); }
section() { printf '== %s\n' "$1"; }

check_contains()
{
	case "$2" in
	*"$3"*) ok "$1" ;;
	*) no "$1 (expected '$3' in output)" ;;
	esac
}

check_absent()
{
	case "$2" in
	*"$3"*) no "$1 (unexpected '$3' in output)" ;;
	*) ok "$1" ;;
	esac
}

# ---------------------------------------------------------------------------
# A fake EVO: every attribute the watch loop reads, seeded with values that pass
# every guard. Individual scenarios then steer one thing at a time.
build_tree()
{
	rm -rf "$TMP/ps" "$TMP/state"
	mkdir -p "$TMP/ps/qcom-battmgr-usb" "$TMP/ps/battery" \
	         "$TMP/ps/hl7139-5f" "$TMP/ps/hl7139-5e" "$TMP/state"
	U=$TMP/ps/qcom-battmgr-usb
	B=$TMP/ps/battery
	M=$TMP/ps/hl7139-5f
	S=$TMP/ps/hl7139-5e

	printf 'Unknown SDP DCP CDP ACA C PD PD_DRP [PD_PPS]\n' > "$U/usb_type"
	printf '1\n' > "$U/online"
	printf '8800000\n' > "$U/voltage_now"
	printf '0\n' > "$U/current_now"
	printf '0\n' > "$U/input_current_limit"

	printf '50\n' > "$B/capacity"
	printf '3900000\n' > "$B/voltage_now"
	printf '5000000\n' > "$B/current_now"
	printf '250\n' > "$B/temp"
	printf 'Charging\n' > "$B/status"
	printf '0\n' > "$B/charge_control_end_threshold"

	for p in "$M" "$S"; do
		# eligible() requires both pumps OFF before a session may start; the
		# policy writes 1 itself when it enables them.
		printf '0\n' > "$p/online"
		printf 'Good\n' > "$p/health"
		printf '1400000\n' > "$p/current_now"
		printf '9050000\n' > "$p/voltage_now"
		printf '450\n' > "$p/temp"
	done
	printf '3950000\n' > "$M/voltage_avg"
	printf '4150000\n' > "$S/voltage_avg"
}

# Shared hook preamble: the adapter follows the request the policy just wrote,
# with the pump VINs a little below it. Without this the rail stops being
# coherent with the pump VINs as the request climbs, and the coherence guard
# fires before the scenario under test ever gets going.
hook_header()
{
	cat > "$TMP/hook.sh" <<'HOOK'
#!/bin/sh
R=$1; S=$2
n=$(cat "$S/hook-n" 2>/dev/null) || n=0
n=$((n + 1))
printf '%s\n' "$n" > "$S/hook-n"
mode=$(cat "$S/hook-mode" 2>/dev/null) || mode=none
U=$R/qcom-battmgr-usb
t=$(cat "$U/voltage_now" 2>/dev/null) || t=8800000
printf '%s\n' "$((t - 30000))" > "$R/hl7139-5f/voltage_now"
printf '%s\n' "$((t - 60000))" > "$R/hl7139-5e/voltage_now"
case "$mode" in
nodep)
	# Healthy for three samples, then a pump stall that still reports
	# online=1 and health=Good -- the 2026-10-02 silent-drain signature.
	if test "$n" -gt 3; then
		printf '0\n' > "$R/hl7139-5f/current_now"
		printf '0\n' > "$R/hl7139-5e/current_now"
	fi
	;;
vin)
	# The adapter holds its operating point ABOVE the request, as it does
	# under falling end-of-charge load, while combined pump input stays under
	# 3.08 A so the integrator keeps winding the request up.
	printf '%s\n' "$t" >> "$S/targets"
	uv=$((t + 400000))
	printf '%s\n' "$uv" > "$U/voltage_now"
	printf '%s\n' "$((uv - 20000))" > "$R/hl7139-5f/voltage_now"
	printf '%s\n' "$((uv - 40000))" > "$R/hl7139-5e/voltage_now"
	# End via the endpoint guard once the windup has had ample time to show.
	if test "$n" -gt 300; then printf '90\n' > "$R/battery/capacity"; fi
	;;
endpoint)
	if test "$n" -gt 5; then printf '90\n' > "$R/battery/capacity"; fi
	;;
esac
exit 0
HOOK
	chmod +x "$TMP/hook.sh"
}

run_session()
{
	printf '%s\n' "$1" > "$TMP/state/hook-mode"
	timeout 90 env \
		ARMADA_POWER_SUPPLY_ROOT="$TMP/ps" \
		ARMADA_CHARGE_MASTER="$TMP/ps/hl7139-5f" \
		ARMADA_CHARGE_SLAVE="$TMP/ps/hl7139-5e" \
		ARMADA_CHARGE_CLEANUP=/bin/true \
		ARMADA_CHARGE_STATE_DIR="$TMP/state" \
		ARMADA_CHARGE_SLEEP_CMD=true \
		ARMADA_CHARGE_SAMPLE_HOOK="$TMP/hook.sh" \
		ARMADA_CHARGE_MAX_EVENTS=1 \
		"$POLICY" > "$TMP/out.txt" 2>&1
	cat "$TMP/out.txt"
}

# ---------------------------------------------------------------------------
section 'a session that reports healthy but delivers nothing must end (no-delivery)'
build_tree
hook_header
out=$(run_session nodep)
check_contains 'the session starts' "$out" 'starting experimental direct charge'
check_contains 'the zero-delivery guard fires' "$out" 'guard: pumps enabled but delivering no current'
check_contains 'it ends as no-delivery, not a fault' "$out" 'session ended: no-delivery'
check_absent 'it does NOT latch a fault' "$out" 'latched fault'
check_absent 'it does NOT demand a cable cycle' "$out" 'unplug the charger'
check_absent 'no other guard claims the session' "$out" 'guard: pump VIN out of range'
check_contains 'it backs off so the stock charger can take over' "$out" 'backing off 120s'

# ---------------------------------------------------------------------------
section 'a stall shorter than the threshold must NOT end the session'
build_tree
hook_header
cat > "$TMP/hook.sh" <<'HOOK'
#!/bin/sh
R=$1; S=$2
n=$(cat "$S/hook-n" 2>/dev/null) || n=0
n=$((n + 1))
printf '%s\n' "$n" > "$S/hook-n"
U=$R/qcom-battmgr-usb
t=$(cat "$U/voltage_now" 2>/dev/null) || t=8800000
printf '%s\n' "$((t - 30000))" > "$R/hl7139-5f/voltage_now"
printf '%s\n' "$((t - 60000))" > "$R/hl7139-5e/voltage_now"
# Stalled for samples 4..43 = 40 samples, under the 60-sample threshold.
if test "$n" -gt 3 && test "$n" -le 43; then
	printf '0\n' > "$R/hl7139-5f/current_now"
	printf '0\n' > "$R/hl7139-5e/current_now"
else
	printf '1400000\n' > "$R/hl7139-5f/current_now"
	printf '1400000\n' > "$R/hl7139-5e/current_now"
fi
if test "$n" -gt 50; then printf '90\n' > "$R/battery/capacity"; fi
exit 0
HOOK
chmod +x "$TMP/hook.sh"
out=$(run_session nodep)
check_absent 'a 40-sample dip does not trip the guard' "$out" 'delivering no current'
check_contains 'the session survives to its endpoint' "$out" 'reached configured 90% limit'

# ---------------------------------------------------------------------------
section 'the endpoint guard ends a session cleanly, without latching'
build_tree
hook_header
out=$(run_session endpoint)
check_contains 'endpoint guard fires' "$out" 'guard: SOC 90% reached configured 90% limit'
check_contains 'it ends as endpoint' "$out" 'session ended: endpoint'
check_absent 'endpoint must not latch' "$out" 'latched fault'
check_absent 'endpoint must not ask for a cable cycle' "$out" 'unplug the charger'

# ---------------------------------------------------------------------------
section 'the request must never wind up past the 10.5 V pump VIN ceiling'
build_tree
hook_header
out=$(run_session vin)
check_contains 'the session starts' "$out" 'starting experimental direct charge'
check_absent 'the VIN guard never fires' "$out" 'guard: pump VIN out of range'
check_absent 'the coherence guard never fires' "$out" 'guard: incoherent'
check_absent 'nothing latches' "$out" 'latched fault'
check_contains 'the session ends at its endpoint instead' "$out" 'session ended: endpoint'
if test -s "$TMP/state/targets"; then
	max=$(sort -n "$TMP/state/targets" | tail -1)
	# The adapter holds the rail 400 mV above the request, so a request below
	# 10.1 V is what keeps the measured VIN under the 10.5 V ceiling.
	if test "$max" -le 10100000; then
		ok "the VIN-headroom regulator held the request under 10.1V (max ${max}uV)"
	else
		no "the request wound up to ${max}uV -- the rail would cross 10.5V"
	fi
	if test "$max" -le 10500000; then
		ok "the request stayed at or below the 10.5V clamp (max ${max}uV)"
	else
		no "the request exceeded the clamp (max ${max}uV)"
	fi
else
	no 'the hook recorded no request values'
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
test "$failed" -eq 0
