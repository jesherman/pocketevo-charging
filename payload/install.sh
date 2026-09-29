#!/bin/bash
# One-time installer for the Pocket EVO 28 W charging pack.
#
# Run as root ON THE DEVICE, from the unpacked bundle directory:
#     sudo ./install.sh
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST=/var/armada/charging
KVER=$(uname -r)
OPTIN=/etc/armada/experimental/pocketevo-direct-charge

[ "$(id -u)" = "0" ] || { echo "ERROR: run this as root (sudo ./install.sh)" >&2; exit 1; }

if [ ! -d "$SRC/modules/$KVER" ]; then
	echo "ERROR: no module pack for the running kernel ($KVER)." >&2
	echo "Bundled kernels:" >&2
	ls -1 "$SRC/modules" 2>/dev/null | sed 's/^/  /' >&2
	echo "Rebuild the pack against $KVER first." >&2
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
