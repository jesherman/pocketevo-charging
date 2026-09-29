#!/bin/bash
# Armada EVO direct-charge pack — (re)apply the 28 W charging stack after an OS update.
#
# WHY THIS EXISTS
#   Armada OS is a bootc/ostree image: every `bootc upgrade` replaces /usr and
#   /boot wholesale, so anything shipped inside the image (the HL7139 driver,
#   the patched battery-manager module, the charge policy) is discarded on each
#   update. /etc and /var, however, SURVIVE updates.
#
#   So the charging stack lives in /var/armada/charging and this script is wired
#   to run at every boot from an /etc systemd unit. Nothing here writes to /usr,
#   /boot or the device tree.
#
# FAILURE POLICY (deliberate)
#   This script must never break a boot and never leave charging worse than
#   stock. Any failure logs, records a status line, and exits 0. A kernel update
#   that has no matching module pack degrades cleanly to the stock ~18 W buck
#   charger — it does NOT insmod a module built for a different kernel (the
#   kernel refuses that anyway).
set -uo pipefail

PACK_ROOT=${PACK_ROOT:-/var/armada/charging}
MOD_ROOT="$PACK_ROOT/modules"
STATUS_FILE="$PACK_ROOT/status"
OPTIN=/etc/armada/experimental/pocketevo-direct-charge
KVER=$(uname -r)
PACK="$MOD_ROOT/$KVER"
I2C_NODE_MATCH="i2c@988000"          # QUP hub carrying the two HL7139 pumps
PUMPS="5f 5e"                        # 0x5f = master, 0x5e = slave
DRIVER_ID="hl7139-evo"

# NOTE: never test module presence with `lsmod | grep -q`: under
# `set -o pipefail` the early-exiting grep SIGPIPEs lsmod, the pipeline reports
# failure, and the caller takes the wrong branch. Read /proc/modules directly.
is_loaded() { grep -q "^$1 " /proc/modules 2>/dev/null; }

log()  { printf '%s  %s\n' "$(date '+%F %T')" "$*"; }
note() { printf '%s\n' "$*" >> "$PACK_ROOT/notes"; }

mkdir -p "$PACK_ROOT"
: > "$PACK_ROOT/notes"

degraded() {
	printf 'degraded: %s\n' "$*" > "$STATUS_FILE"
	log "DEGRADED: $*"
	exit 0
}

# --- 1. is there a module pack for the RUNNING kernel? ----------------------------
# The pack is keyed on the kernel release because the modules must match it
# exactly; an image update that does not bump the kernel needs no new pack.
if [ ! -d "$PACK" ]; then
	degraded "no charging module pack for kernel $KVER; stock charging in use"
fi
for m in qcom_battmgr.ko hl7139_evo.ko; do
	[ -f "$PACK/$m" ] || degraded "module pack $KVER is incomplete ($m missing)"
done
log "applying charging pack for kernel $KVER"

# --- 2. patched qcom_battmgr: PPS voltage + input-current setters -----------------
# Identity check without srcversion: the patched driver declares VOLTAGE_NOW and
# INPUT_CURRENT_LIMIT writable, so power_supply exposes them 0644. The stock
# module leaves them read-only (0444).
attr_mode() { stat -c %a "$1" 2>/dev/null || echo 000; }
USB_PS=/sys/class/power_supply/qcom-battmgr-usb

# The USB supply only appears once the ADSP/pmic-glink is up; without it the
# mode probe below would read 000 and trigger a pointless reload.
for _ in $(seq 1 30); do
	[ -e "$USB_PS/voltage_now" ] && break
	sleep 1
done

if is_loaded qcom_battmgr; then
	if [ "$(attr_mode "$USB_PS/voltage_now")" != "644" ]; then
		log "replacing stock qcom_battmgr with the patched build"
		if rmmod qcom_battmgr 2>/dev/null; then
			sleep 1
			if ! out=$(insmod "$PACK/qcom_battmgr.ko" 2>&1); then
				log "WARN: insmod patched qcom_battmgr failed: $out"
				modprobe qcom_battmgr 2>/dev/null || true
				note "qcom_battmgr: patched insmod failed ($out)"
			else
				log "patched qcom_battmgr loaded"
			fi
		else
			log "WARN: rmmod qcom_battmgr failed (module in use); keeping stock"
			note "qcom_battmgr: rmmod failed"
		fi
	fi
else
	# Not loaded at all (initramfs did not bring it up): load ours directly.
	out=$(insmod "$PACK/qcom_battmgr.ko" 2>&1) || {
		log "WARN: insmod qcom_battmgr failed: $out"
		modprobe qcom_battmgr 2>/dev/null || true
	}
fi

# --- 3. HL7139 charge-pump driver ------------------------------------------------
if ! is_loaded hl7139_evo; then
	if out=$(insmod "$PACK/hl7139_evo.ko" 2>&1); then
		log "hl7139_evo driver loaded"
	else
		log "WARN: insmod hl7139_evo failed: $out"
		note "hl7139_evo: $out"
	fi
fi

# --- 4. instantiate the two pumps (no device-tree nodes exist for them) ----------
# The armada kernel has CONFIG_OF_OVERLAY=y but its DTBs are built without
# __symbols__, so a runtime overlay cannot use &i2c_hub_2 / &tlmm labels. The
# driver therefore also registers an i2c_device_id of its own ("hl7139-evo",
# distinct from the in-kernel "hl7139-charger" driver for other boards) and we
# instantiate the pumps through the standard sysfs new_device interface.
find_i2c_bus() {
	local a n t
	for a in /sys/bus/i2c/devices/i2c-*; do
		[ -L "$a/of_node" ] || continue
		t=$(readlink -f "$a/of_node" 2>/dev/null) || continue
		case "$t" in *"$I2C_NODE_MATCH"*) n=${a##*/i2c-}; printf '%s' "$n"; return 0 ;; esac
	done
	return 1
}

BUS=""
for _ in $(seq 1 30); do
	BUS=$(find_i2c_bus) && break
	sleep 1
done
if [ -z "$BUS" ]; then
	degraded "i2c bus $I2C_NODE_MATCH not found; pumps not instantiated"
fi
log "HL7139 pumps live on i2c-$BUS"

for addr in $PUMPS; do
	dev="/sys/bus/i2c/devices/$BUS-00$addr"
	[ -e "$dev" ] && continue
	if out=$(echo "$DRIVER_ID 0x$addr" > "/sys/bus/i2c/devices/i2c-$BUS/new_device" 2>&1); then
		log "instantiated $DRIVER_ID at 0x$addr"
	else
		log "WARN: instantiate 0x$addr failed: $out"
		note "new_device 0x$addr: $out"
	fi
done

# --- 5. verify ------------------------------------------------------------------
missing=""
for addr in $PUMPS; do
	[ -e "/sys/class/power_supply/hl7139-$addr" ] || missing="$missing hl7139-$addr"
done
if [ -n "$missing" ]; then
	degraded "pump supplies missing:$missing"
fi

# --- 6. opt-in flag (owned by the installer / control script, only reported here) --
flag="off"
[ -e "$OPTIN" ] && flag="on"

printf 'ok: kernel %s, pumps hl7139-5f+hl7139-5e, direct-charge opt-in %s\n' \
	"$KVER" "$flag" > "$STATUS_FILE"
log "charging pack applied (direct-charge opt-in: $flag)"
exit 0
