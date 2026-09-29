#!/usr/bin/env bash
#
# Copy a built bundle to a Pocket EVO and install it there.
#
#   ./deploy.sh <bundle.tar.gz> <user@host>
#   ./deploy.sh dist/charging-pack-7.2.6.tar.gz user@device.local
#
# Requires ssh + scp to the device (the device's SSH server must be enabled).
set -euo pipefail

BUNDLE="${1:-}"
TARGET="${2:-}"

if [ -z "$BUNDLE" ] || [ -z "$TARGET" ]; then
	sed -n '3,9p' "$0"
	exit 1
fi
[ -f "$BUNDLE" ] || { echo "ERROR: no such bundle: $BUNDLE" >&2; exit 1; }

REMOTE=/tmp/$(basename "$BUNDLE")

echo "==> copying $(basename "$BUNDLE") to $TARGET"
scp "$BUNDLE" "$TARGET:$REMOTE"

echo "==> installing"
ssh -t "$TARGET" "
set -e
rm -rf /tmp/charging-pack
mkdir -p /tmp/charging-pack
tar -xzf $REMOTE -C /tmp/charging-pack --strip-components=1
chmod +x /tmp/charging-pack/install.sh
sudo /tmp/charging-pack/install.sh
"
