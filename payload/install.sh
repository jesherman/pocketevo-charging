#!/bin/bash
# One-time installer for the Pocket EVO 28 W charging pack.
#
# Run as root ON THE DEVICE, from the unpacked bundle directory:
#     sudo ./install.sh
#     sudo ./install.sh --force     override the provenance check below
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST=/var/armada/charging
KVER=$(uname -r)
OPTIN=/etc/armada/experimental/pocketevo-direct-charge
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

[ "$(id -u)" = "0" ] || { echo "ERROR: run this as root (sudo ./install.sh)" >&2; exit 1; }

if [ ! -d "$SRC/modules/$KVER" ]; then
	echo "ERROR: no module pack for the running kernel ($KVER)." >&2
	echo "Bundled kernels:" >&2
	ls -1 "$SRC/modules" 2>/dev/null | sed 's/^/  /' >&2
	echo "Rebuild the pack against $KVER first." >&2
	exit 1
fi

# --- provenance gate ---------------------------------------------------------------
# A kernel release string cannot tell two 7.2.6 kernels apart (armada has shipped
# at least two different 7.2.6 patch sets), so the bundle records the exact armada
# commit it was built from and we compare that against the image this device is
# actually running. Installing a pack built for a different tree would hand the
# kernel modules compiled against source it never saw -- and because
# CONFIG_MODVERSIONS is off, the kernel would accept them anyway. Refuse instead.
IMAGE_VER=$(sed -n 's/^IMAGE_VERSION="\?\([^"]*\)"\?$/\1/p' /etc/os-release 2>/dev/null | head -1)
IMAGE_COMMIT=${IMAGE_VER##*.}
PACK_COMMIT=""
[ -f "$SRC/PACK-META" ] && PACK_COMMIT=$(sed -n 's/^armada_commit=//p' "$SRC/PACK-META" | head -1)

if [ -n "$PACK_COMMIT" ] && [ -n "$IMAGE_COMMIT" ]; then
	if [ "${PACK_COMMIT:0:7}" != "$IMAGE_COMMIT" ]; then
		if [ "$FORCE" = "1" ]; then
			echo "WARN: pack built from armada ${PACK_COMMIT:0:7}, image is $IMAGE_VER -- continuing (--force)" >&2
		else
			cat >&2 <<EOF
ERROR: this pack was built for a different image.

  pack built from : armada ${PACK_COMMIT:0:7}
  device running  : $IMAGE_VER

Rebuild the pack against this image, or pass --force if you have a specific
reason to run modules from another kernel (they will still be fingerprint-gated
at boot, so they will be refused unless you also record a new baseline).
EOF
			exit 1
		fi
	fi
else
	[ -n "$PACK_COMMIT" ] || echo "WARN: bundle has no PACK-META; cannot verify which image it was built for" >&2
fi

# The identity gate is only worth anything if we can actually compute a
# fingerprint, which means the image's power-supply modules being present. If that
# directory ever moves, refuse here rather than install a pack that will silently
# degrade at every boot.
MODBASE="/usr/lib/modules/$KVER"
if ! ls "$MODBASE/kernel/drivers/power/supply"/*.ko >/dev/null 2>&1; then
	echo "ERROR: cannot fingerprint this kernel (no modules under $MODBASE/kernel/drivers/power/supply)." >&2
	echo "       Refusing to install a pack that cannot be identity-checked at boot." >&2
	exit 1
fi

echo "==> installing into $DEST"
install -d -m 0755 "$DEST/bin" "$DEST/modules" "$DEST/state"
install -m 0755 "$SRC"/bin/*.sh "$DEST/bin/"
for f in armada-pocketevo-charge-policy armada-pocketevo-charge-cleanup; do
	[ -f "$SRC/bin/$f" ] && install -m 0755 "$SRC/bin/$f" "$DEST/bin/$f"
done
cp -a "$SRC/modules/." "$DEST/modules/"
[ -f "$SRC/README.md" ] && install -m 0644 "$SRC/README.md" "$DEST/README.md"

echo "==> installing systemd units"
install -m 0644 "$SRC"/systemd/*.service /etc/systemd/system/

# The pack exists to provide this mode, so opt in by default. Remove this file
# (or use charging-control.sh disable) to fall back to the stock charger.
install -d -m 0755 "$(dirname "$OPTIN")"
touch "$OPTIN"

echo "==> enabling services"
systemctl daemon-reload
systemctl enable armada-charging-pack.service >/dev/null
systemctl enable armada-pocketevo-charge-policy.service >/dev/null
if [ -d "$SRC/udev" ]; then
	install -m 0644 "$SRC"/udev/*.rules /etc/udev/rules.d/
	udevadm control --reload-rules 2>/dev/null || true
fi

# Record the fingerprint of the kernel we are validating this pack against. This
# is the one and only moment the pack is allowed to declare a kernel acceptable:
# here a human chose the bundle, it was built for this image, and the module pack
# matches the running release. From now on the applier only compares.
echo "==> recording the kernel fingerprint this pack is validated against"
ARMADA_COMMIT="$PACK_COMMIT" MODBASE="$MODBASE" PACK_ROOT="$DEST" \
	"$DEST/bin/charging-kernel-fingerprint.sh" record
"$DEST/bin/charging-kernel-fingerprint.sh" show | sed -n '/^image=/,$p' | sed 's/^/    /'

systemctl restart armada-charging-pack.service
systemctl restart armada-pocketevo-charge-policy.service 2>/dev/null || true

echo "==> desktop launcher"
if [ -d /home/armada ]; then
	install -m 0755 "$SRC/desktop/28W-Charging.desktop" /home/armada/Desktop/28W-Charging.desktop 2>/dev/null || true
	install -m 0755 "$SRC/desktop/28W-Charging.sh" /home/armada/28W-Charging.sh 2>/dev/null || true
	chown armada:armada /home/armada/Desktop/28W-Charging.desktop /home/armada/28W-Charging.sh 2>/dev/null || true
	install -d -m 0755 /home/armada/.local/share/applications
	install -m 0755 "$SRC/desktop/28W-Charging.desktop" /home/armada/.local/share/applications/ 2>/dev/null || true
	chown -R armada:armada /home/armada/.local/share/applications 2>/dev/null || true
fi

echo
sleep 2
"$DEST/bin/charging-control.sh" status || true
echo
echo "Done. The pack re-applies itself on every boot."
