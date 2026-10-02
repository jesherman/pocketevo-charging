#!/bin/bash
# Exercise the charging pack's kernel-identity gate against a fake kernel tree.
#
# The gate is the only thing standing between an armada image update and modules
# compiled for a kernel that is no longer there, so it gets a test. Nothing here
# touches the real /var/armada/charging, loads a module, or needs root: the applier
# is driven in --check mode, which stops immediately after the gate.
#
#   ./tests/gate-test.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
KVER="$(uname -r)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PACK="$TMP/pack"
MODBASE="$TMP/modules/$KVER"
SUBSYS="$MODBASE/kernel/drivers/power/supply"
export PACK_ROOT="$PACK" MODBASE
mkdir -p "$PACK/bin" "$PACK/modules/$KVER" "$PACK/state"
install -m 0755 "$REPO"/payload/bin/*.sh "$PACK/bin/"
: > "$PACK/modules/$KVER/qcom_battmgr.ko"
: > "$PACK/modules/$KVER/hl7139_evo.ko"

# A plausible image kernel. The *shape* mirrors the real one -- vmlinuz plus the
# subsystem modules the pack compiles against -- and every call produces genuinely
# different byte content.
new_kernel() {
	mkdir -p "$SUBSYS"
	head -c 4096 /dev/urandom > "$MODBASE/vmlinuz"
	printf 'Patches applied: %s\n' "$1" > "$MODBASE/.armada-source"
	head -c 512 /dev/urandom > "$SUBSYS/qcom_battmgr.ko"
	head -c 512 /dev/urandom > "$SUBSYS/max17042_battery.ko"
	head -c 512 /dev/urandom > "$SUBSYS/sbs-battery.ko"
}
# armada rebuilt the kernel but touched nothing the pack depends on.
rebuilt_kernel_only() { head -c 4096 /dev/urandom > "$MODBASE/vmlinuz"; }

record()      { ARMADA_COMMIT=deadbeef "$PACK/bin/charging-kernel-fingerprint.sh" record; }
apply_check() { bash "$REPO/payload/bin/charging-pack-apply.sh" --check 2>&1; }
status()      { cat "$PACK/status" 2>/dev/null; }

pass=0; fail=0
expect() { # <description> <expected substring> <actual>
	if [[ "$3" == *"$2"* ]]; then
		printf '  ok    %s\n' "$1"; pass=$((pass + 1))
	else
		printf '  FAIL  %s\n          wanted: %s\n          got:    %s\n' \
			"$1" "$2" "${3//$'\n'/ | }"; fail=$((fail + 1))
	fi
}

new_kernel 171

echo "== no baseline recorded: must refuse (fail closed)"
rm -f "$PACK/state/kernel-fingerprint" "$PACK/status"
apply_check >/dev/null
expect "refuses without a baseline" "no kernel fingerprint on record" "$(status)"

echo "== baseline recorded, nothing changed: must load"
record
expect "opens on a matching kernel" "match for $KVER" "$(apply_check)"

echo "== armada rebuilt the kernel, power-supply ABI untouched: must still load"
# The measured case (311ed3b -> 72f2a63). Refusing here would cost a 40-minute
# kernel rebuild for a pack that is provably still correct, which is exactly why
# the gate does not fingerprint vmlinuz.
rebuilt_kernel_only
expect "ignores a kernel rebuild that left the subsystem alone" "match for $KVER" "$(apply_check)"

echo "== the stock qcom_battmgr.ko we replace changed: must refuse"
new_kernel 174; record
head -c 512 /dev/urandom > "$SUBSYS/qcom_battmgr.ko"
apply_check >/dev/null
expect "refuses when the replaced ABI surface changed" "image kernel changed" "$(status)"
expect "names the image it was validated on" "last validated on" "$(cat "$PACK/notes")"
expect "dumps the recorded fingerprint" "recorded" "$(cat "$PACK/notes")"

echo "== a neighbouring power-supply module changed: must refuse"
new_kernel 174; record
head -c 512 /dev/urandom > "$SUBSYS/max17042_battery.ko"
apply_check >/dev/null
expect "refuses on a subsystem-wide change" "image kernel changed" "$(status)"

echo "== armada added a power-supply module: must refuse"
new_kernel 174; record
head -c 512 /dev/urandom > "$SUBSYS/newly_added_charger.ko"
apply_check >/dev/null
expect "refuses when a module is added" "image kernel changed" "$(status)"

echo "== a module vanished: must refuse"
new_kernel 174; record
rm -f "$SUBSYS/sbs-battery.ko"
apply_check >/dev/null
expect "refuses when a module disappears" "image kernel changed" "$(status)"

echo "== the subsystem moved and cannot be fingerprinted: must refuse"
new_kernel 174; record
rm -rf "$SUBSYS"
apply_check >/dev/null
expect "refuses when it cannot fingerprint at all" "cannot fingerprint this kernel" "$(status)"

echo "== the documented escape hatch"
new_kernel 174; record
new_kernel 175
expect "honours ARMADA_CHARGING_SKIP_FINGERPRINT=1" "gate bypassed" \
	"$(ARMADA_CHARGING_SKIP_FINGERPRINT=1 apply_check)"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
