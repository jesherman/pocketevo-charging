#!/usr/bin/env bash
#
# Build a Pocket EVO charging pack bundle for an armada kernel.
#
#   ./build/build-pack.sh
#   ARMADA_REF=main JOBS=12 ./build/build-pack.sh
#
# Output: dist/charging-pack-<kernelrelease>.tar.gz (+ .sha256)
#
# The bundle is what you copy to the device and hand to payload/install.sh. It
# contains the patched qcom_battmgr, the out-of-tree hl7139_evo driver, and the
# installer/units/policy, keyed by the kernel release they were built against.
#
# Nothing from armada is vendored in this repository: packages/kernel is fetched
# at ARMADA_REF and the three patches in patches/ are applied on top of it.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARMADA_REPO="${ARMADA_REPO:-https://github.com/armada-os/armada.git}"
ARMADA_REF="${ARMADA_REF:-main}"
ARCH="${ARCH:-arm64}"
CROSS="${CROSS_COMPILE:-aarch64-linux-gnu-}"
WORK="${WORK:-$REPO/.work}"
OUT="${OUT:-$REPO/dist}"
JOBS="${JOBS:-$(nproc)}"

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for tool in git make "${CROSS}gcc" "${CROSS}objcopy"; do
	command -v "$tool" >/dev/null 2>&1 || die "$tool not found on PATH (see README, 'Building')"
done

mkdir -p "$WORK" "$OUT"

# --- 1. the armada kernel template -------------------------------------------
if [ ! -d "$WORK/armada/.git" ]; then
	log "cloning $ARMADA_REPO (sparse: packages/kernel only)"
	git clone --filter=blob:none --no-checkout "$ARMADA_REPO" "$WORK/armada"
	git -C "$WORK/armada" sparse-checkout init --cone
	git -C "$WORK/armada" sparse-checkout set packages/kernel
fi
log "checking out $ARMADA_REF"
git -C "$WORK/armada" fetch --depth 1 origin "$ARMADA_REF"
# -f is required on re-runs: the previous run appended our patches to the
# tracked patches/series, and a plain checkout refuses to clobber it.
git -C "$WORK/armada" checkout -f --detach FETCH_HEAD --quiet

PKG="$WORK/armada/packages/kernel"
[ -d "$PKG" ] || die "packages/kernel missing in armada@$ARMADA_REF"

KERNEL_VERSION="$(sed -n 's/^VERSION=//p' "$PKG/BASE.env" | head -1)"
[ -n "$KERNEL_VERSION" ] || die "could not read VERSION from $PKG/BASE.env"
log "armada kernel version: $KERNEL_VERSION"

# --- 2. our patches on top of armada's series --------------------------------
# They must come AFTER armada's own qcom_battmgr patches (0901/0902/0903),
# which is why they are appended at the end of the series.
cp "$REPO"/patches/*.patch "$PKG/patches/"
{
	printf '\n# Pocket EVO direct charge (pocketevo-charging pack)\n'
	for p in "$REPO"/patches/*.patch; do basename "$p"; done
} >> "$PKG/patches/series"

# --- 3. kernel ----------------------------------------------------------------
# build-kernel.sh reads JOBS from nproc; pass it what we want via PATH-friendly
# wrapper only if the caller asked for something specific.
log "building kernel $KERNEL_VERSION with $JOBS jobs (this is the slow part)"
if [ "$JOBS" != "$(nproc)" ] && command -v taskset >/dev/null 2>&1; then
	log "note: build-kernel.sh uses nproc internally; JOBS=$JOBS cannot be enforced"
fi
WORK_DIR="$WORK" OUT_DIR="$OUT" bash "$PKG/scripts/build-kernel.sh"

KD="$WORK/linux-$KERNEL_VERSION"
[ -f "$KD/Module.symvers" ] || die "kernel tree $KD is not fully built"
KREL="$(make -s -C "$KD" ARCH="$ARCH" CROSS_COMPILE="$CROSS" kernelrelease)"
[ -n "$KREL" ] || die "could not determine kernelrelease"
log "kernel release: $KREL"

# --- 4. the two modules -------------------------------------------------------
# Built in a scratch copy so the repository itself stays clean.
DRV="$WORK/driver"
rm -rf "$DRV"
cp -r "$REPO/driver" "$DRV"

log "building hl7139_evo.ko (out-of-tree)"
make -C "$KD" M="$DRV" ARCH="$ARCH" CROSS_COMPILE="$CROSS" modules

MODDIR="$WORK/modules/$KREL"
rm -rf "$MODDIR"
mkdir -p "$MODDIR"
cp "$DRV/hl7139_evo.ko" "$MODDIR/"
BATT_MGR="$(find "$KD/drivers/power/supply" -name 'qcom_battmgr.ko' | head -1)"
[ -n "$BATT_MGR" ] || die "qcom_battmgr.ko not found under $KD"
cp "$BATT_MGR" "$MODDIR/"

# Strip BTF. An in-tree module carries SPLIT BTF (.BTF + .BTF.base); at load
# time the kernel validates .BTF.base against the RUNNING kernel's vmlinux BTF
# and refuses the module when the base type IDs do not line up, which they never
# will for a module built elsewhere:
#
#   failed to validate module [qcom_battmgr] BTF: -22
#   insmod: ERROR: could not insert module qcom_battmgr.ko: Invalid parameters
#
# Module BTF only feeds BPF/CO-RE introspection, and with no .BTF section the
# kernel skips validation entirely.
log "stripping BTF from shipped modules"
for m in "$MODDIR"/*.ko; do
	"${CROSS}objcopy" --remove-section=.BTF --remove-section=.BTF.base "$m"
done

log "verifying vermagic"
for m in "$MODDIR"/*.ko; do
	vm="$(tr '\0' '\n' < "$m" | grep -m1 '^vermagic=' || true)"
	printf '    %-20s %s\n' "$(basename "$m")" "$vm" >&2
done

# --- 5. bundle ----------------------------------------------------------------
BUNDLE="$WORK/bundle"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE"/{bin,systemd,udev,desktop} "$BUNDLE/modules/$KREL"
cp "$REPO/payload/install.sh" "$BUNDLE/"
cp "$REPO/README.md" "$BUNDLE/"
cp "$REPO"/payload/bin/* "$BUNDLE/bin/"
cp "$REPO"/payload/systemd/*.service "$BUNDLE/systemd/"
cp "$REPO"/payload/udev/*.rules "$BUNDLE/udev/"
cp "$REPO"/payload/desktop/* "$BUNDLE/desktop/"
cp "$MODDIR"/*.ko "$BUNDLE/modules/$KREL/"
chmod 0755 "$BUNDLE/install.sh" "$BUNDLE"/bin/*

TGZ="$OUT/charging-pack-$KREL.tar.gz"
log "packing $TGZ"
tar -C "$WORK" -czf "$TGZ" bundle
( cd "$OUT" && sha256sum "$(basename "$TGZ")" > "$(basename "$TGZ").sha256" )

echo
cat "$OUT/$(basename "$TGZ").sha256"
log "done — copy $TGZ to the device and run: sudo ./install.sh"
