#!/bin/bash
# Pocket EVO charging pack — device-observed kernel fingerprint.
#
#   charging-kernel-fingerprint.sh record   record the RUNNING kernel as the baseline
#   charging-kernel-fingerprint.sh check    exit 0 = matches, 1 = changed, 2 = no baseline
#   charging-kernel-fingerprint.sh show     print the recorded provenance
#   charging-kernel-fingerprint.sh live     print the running kernel's fingerprint
#
# WHY THIS EXISTS
#   The charging pack's modules are keyed on the kernel release string, but the
#   release does not identify the kernel. armada has shipped at least two distinct
#   7.2.6 kernels built from different patch sets, and `uname -r` reports "7.2.6"
#   for both. Because CONFIG_MODVERSIONS is off there is no symbol CRC for the
#   kernel to check either, so a module compiled against the wrong build loads
#   cleanly and the pack reports success while running code that was never built
#   for that kernel. That happened for real on 2026-10-01: image
#   20260928.311ed3b -> 20261001.72f2a63, same "7.2.6", and nothing noticed.
#
# WHAT IS FINGERPRINTED, AND WHY NOT THE KERNEL
#   Every module armada ships for the power-supply subsystem — the interface this
#   pack actually compiles against. Deliberately NOT vmlinuz.
#
#   Measured 2026-10-02 across exactly that update: armada added three kernel
#   patches (arm64 unaligned atomics, drm/msm submitqueue, input/rsinput) and
#   vmlinuz changed — but every module under drivers/power/supply/ came out
#   byte-identical, including the stock qcom_battmgr.ko this pack replaces, and
#   so did the pack's own patched build. Keying the gate on vmlinuz would have
#   refused a pack that was provably still correct and demanded a 40-minute kernel
#   rebuild for nothing. Keying it on this subsystem refuses exactly when the
#   interface actually moves, which is when a rebuild is genuinely required.
#
#   Hashing our own build output would be useless: our cross build and armada's CI
#   build are different compilations and can never match byte for byte. Comparing
#   the device against its own earlier self is the only meaningful comparison.
#
# The applier only ever calls `check`. It never records: adopting a new kernel by
# itself is precisely the failure this guards against. Only install.sh records, and
# only after verifying the bundle was built for the running image.
set -uo pipefail

PACK_ROOT=${PACK_ROOT:-/var/armada/charging}
KVER=${KVER:-$(uname -r)}
MODBASE=${MODBASE-/usr/lib/modules/$KVER}
FP_FILE=${FP_FILE:-$PACK_ROOT/state/kernel-fingerprint}
SUBSYS="kernel/drivers/power/supply"

# The compared set, in a stable order. If the directory disappears or is renamed
# this yields nothing, and `check` reports "no usable records" rather than passing.
fingerprint() {
	local f h
	for f in $(ls -1 "$MODBASE/$SUBSYS"/*.ko 2>/dev/null | sort); do
		h=$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)
		printf '%s  %s\n' "${h:-UNREADABLE}" "$f"
	done
}

# Informational, never compared: lets `show` report "armada rebuilt the kernel, the
# charging ABI is unchanged" instead of leaving a silent gap.
image_version() {
	sed -n 's/^IMAGE_VERSION="\?\([^"]*\)"\?$/\1/p' /etc/os-release 2>/dev/null | head -1
}
kernel_image_hash() {
	[ -f "$MODBASE/vmlinuz" ] || { printf 'unknown'; return; }
	sha256sum "$MODBASE/vmlinuz" 2>/dev/null | cut -d' ' -f1
}

case "${1:-check}" in
record)
	install -d -m 0755 "$(dirname "$FP_FILE")"
	{
		printf '# Pocket EVO charging pack -- device-observed kernel fingerprint.\n'
		printf '# Recorded when this pack was validated on this kernel. The applier refuses\n'
		printf '# to load the pack if any listed module changes.\n'
		printf '# Compared: the power-supply subsystem below.\n'
		printf '# Informational only (not compared): image, armada_commit, vmlinuz.\n'
		printf 'image=%s\n'         "$(image_version)"
		printf 'armada_commit=%s\n' "${ARMADA_COMMIT:-unknown}"
		printf 'vmlinuz=%s\n'       "$(kernel_image_hash)"
		fingerprint
	} > "$FP_FILE"
	chmod 0644 "$FP_FILE"
	;;
check)
	[ -s "$FP_FILE" ] || exit 2
	# Only the fingerprint records are compared: "image=", "armada_commit=" and
	# "vmlinuz=" carry provenance and are deliberately excluded. (An earlier version
	# compared every non-comment line, which made the gate refuse unconditionally.)
	rec=$(grep -E '^([0-9a-f]{64}|UNREADABLE)  ' "$FP_FILE" || true)
	[ -n "$rec" ] || exit 2
	live=$(fingerprint)
	[ -n "$live" ] || exit 3          # nothing to compare against: cannot verify
	[ "$live" = "$rec" ] || exit 1
	;;
live)
	fingerprint
	;;
show)
	if [ -s "$FP_FILE" ]; then cat "$FP_FILE"; else echo "no baseline recorded"; fi
	;;
*)
	sed -n '2,12p' "$0"; exit 1
	;;
esac
