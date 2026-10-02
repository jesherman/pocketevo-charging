#!/usr/bin/env bash
#
# Stage and pack the Pocket EVO charging bundle from an existing kernel build.
#
#   ./build/make-bundle.sh [kernel-release]
#
# build-pack.sh spends ~40 minutes in the kernel before it touches payload/. That
# is pure waste when you are iterating on the installer, the units, the policy or
# the fingerprint helper: the modules in .work/modules/<krel>/ are already built
# and correct. This stages the bundle from those modules plus the current working
# tree, so payload changes are a two-second operation.
#
# With no argument the kernel release is taken from .work/modules/. It is a
# separate script rather than a flag on build-pack.sh so that there is exactly one
# implementation of "what goes in the bundle" — build-pack.sh calls this too.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$REPO/.work}"
OUT="${OUT:-$REPO/dist}"
ARMADA_REPO="${ARMADA_REPO:-https://github.com/armada-os/armada.git}"

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

KREL="${1:-}"
if [ -z "$KREL" ]; then
	MODDIR=$(find "$WORK/modules" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
	[ -n "$MODDIR" ] || die "no built modules under $WORK/modules (run build-pack.sh first)"
	KREL="$(basename "$MODDIR")"
fi
MODDIR="$WORK/modules/$KREL"
[ -d "$MODDIR" ] || die "no built modules for kernel release $KREL"
for m in qcom_battmgr.ko hl7139_evo.ko; do
	[ -f "$MODDIR/$m" ] || die "$MODDIR is missing $m (run build-pack.sh first)"
done

[ -d "$WORK/armada/.git" ] || die "no armada tree at $WORK/armada; cannot record provenance"

# The kernel version comes from the source tree the modules were built against.
KD=$(find "$WORK" -mindepth 1 -maxdepth 1 -type d -name 'linux-*' 2>/dev/null | head -1)
KERNEL_VERSION=""
[ -n "$KD" ] && KERNEL_VERSION="$(basename "$KD" | sed 's/^linux-//')"

BUNDLE="$WORK/bundle"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE"/{bin,systemd,udev,desktop} "$BUNDLE/modules/$KREL"

log "staging the bundle for $KREL"
cp "$REPO/payload/install.sh" "$BUNDLE/"
cp "$REPO/README.md" "$BUNDLE/"
cp "$REPO"/payload/bin/* "$BUNDLE/bin/"
cp "$REPO"/payload/systemd/*.service "$BUNDLE/systemd/"
cp "$REPO"/payload/udev/*.rules "$BUNDLE/udev/"
cp "$REPO"/payload/desktop/* "$BUNDLE/desktop/"
cp "$MODDIR"/*.ko "$BUNDLE/modules/$KREL/"
chmod 0755 "$BUNDLE/install.sh" "$BUNDLE"/bin/*

# Provenance for the installer's gate. A kernel release string cannot distinguish
# two 7.2.6 builds, so record the exact armada commit the modules were compiled
# from: install.sh compares it against the image the device is running and refuses
# a bundle built for a different tree. The ref is resolved to a commit even when
# the caller passed a branch name, so the record is always exact.
ARMADA_COMMIT="$(git -C "$WORK/armada" rev-parse HEAD)"
{
	printf 'armada_repo=%s\n'     "$ARMADA_REPO"
	printf 'armada_commit=%s\n'   "$ARMADA_COMMIT"
	printf 'kernel_version=%s\n'  "${KERNEL_VERSION:-unknown}"
	printf 'kernel_release=%s\n'  "$KREL"
	printf 'built=%s\n'           "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	for m in "$BUNDLE/modules/$KREL"/*.ko; do
		printf 'module %s %s\n' "$(sha256sum "$m" | cut -d' ' -f1)" "$(basename "$m")"
	done
} > "$BUNDLE/PACK-META"
log "PACK-META: armada ${ARMADA_COMMIT:0:7}, kernel ${KERNEL_VERSION:-unknown} / $KREL"

mkdir -p "$OUT"
TGZ="$OUT/charging-pack-$KREL.tar.gz"
log "packing $TGZ"
tar -C "$WORK" -czf "$TGZ" bundle
( cd "$OUT" && sha256sum "$(basename "$TGZ")" > "$(basename "$TGZ").sha256" )
cat "$OUT/$(basename "$TGZ").sha256"
