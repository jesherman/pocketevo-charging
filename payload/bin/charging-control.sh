#!/bin/bash
# Armada EVO 28 W charging — status and control.
#
#   charging-control.sh status     show what is actually active right now
#   charging-control.sh apply      re-apply the pack (after an OS update)
#   charging-control.sh enable     turn the experimental direct-charge policy ON
#   charging-control.sh disable    turn it OFF (back to the stock buck charger)
#   charging-control.sh menu       interactive menu (used by the Desktop icon)
#
# Only `status` works unprivileged; the rest self-elevate with sudo, which is
# why the Desktop icon opens a terminal rather than a kdialog box.
set -uo pipefail

PACK_ROOT=${PACK_ROOT:-/var/armada/charging}
APPLY="$PACK_ROOT/bin/charging-pack-apply.sh"
OPTIN=/etc/armada/experimental/pocketevo-direct-charge
UNIT=armada-pocketevo-charge-policy.service
USB=/sys/class/power_supply/qcom-battmgr-usb
BAT=/sys/class/power_supply/battery
rd() { [ -r "$1" ] && cat "$1" 2>/dev/null; }

# NOTE: never test module presence with `lsmod | grep -q`: under
# `set -o pipefail` the early-exiting grep SIGPIPEs lsmod, the pipeline reports
# failure, and the caller takes the wrong branch. Read /proc/modules directly.
is_loaded() { grep -q "^$1 " /proc/modules 2>/dev/null; }

status_text() {
	local kver mod_state battmgr pumps flag unit v i total pump kident
	kver=$(uname -r)

	if is_loaded qcom_battmgr; then
		if [ "$(stat -c %a "$USB/voltage_now" 2>/dev/null || echo 000)" = "644" ]; then
			battmgr="patched (PPS voltage control available)"
		else
			battmgr="STOCK (no PPS control -> 18 W cap)"
		fi
	else
		battmgr="not loaded"
	fi

	if is_loaded hl7139_evo; then
		pumps="driver loaded"
		[ -e /sys/class/power_supply/hl7139-5f ] || pumps="$pumps, master MISSING"
		[ -e /sys/class/power_supply/hl7139-5e ] || pumps="$pumps, slave MISSING"
	else
		pumps="driver NOT loaded"
	fi

	[ -d "$PACK_ROOT/modules/$kver" ] && mod_state="present" || mod_state="MISSING for $kver"
	[ -e "$OPTIN" ] && flag="on" || flag="off"
	unit=$(systemctl is-active "$UNIT" 2>/dev/null) || true
	[ -n "$unit" ] || unit=inactive

	# The kernel-identity gate: the module pack is keyed on the release string, and
	# armada has shipped more than one distinct 7.2.6, so "present" above does not
	# mean the modules match the running kernel. Report the real verdict.
	local fp fp_img rc
	fp="$PACK_ROOT/bin/charging-kernel-fingerprint.sh"
	if [ -x "$fp" ]; then
		fp_img=$("$fp" show 2>/dev/null | sed -n 's/^image=//p' | head -1)
		KVER="$kver" "$fp" check; rc=$?
		case $rc in
			0) kident="matches (validated on ${fp_img:-unknown})" ;;
			2) kident="no baseline recorded" ;;
			3) kident="cannot fingerprint this kernel" ;;
			*) kident="CHANGED since ${fp_img:-unknown} -- pack will not load" ;;
		esac
	else
		kident="helper missing"
	fi

	printf '  kernel:          %s\n' "$kver"
	printf '  module pack:     %s\n' "$mod_state"
	printf '  kernel identity: %s\n' "$kident"
	printf '  qcom_battmgr:    %s\n' "$battmgr"
	printf '  HL7139 pumps:    %s\n' "$pumps"
	printf '  direct charge:   %s\n' "$flag"
	printf '  policy service:  %s\n' "$unit"
	[ -r "$PACK_ROOT/status" ] && printf '  last apply:      %s\n' "$(cat "$PACK_ROOT/status")"

	# During direct charge the power flows through the two HL7139 pumps and the
	# Qualcomm buck reads ~0 A, so the pumps are the number that matters.
	total=0
	for pump in hl7139-5f hl7139-5e; do
		v=$(rd "/sys/class/power_supply/$pump/voltage_now")
		i=$(rd "/sys/class/power_supply/$pump/current_now")
		[ -n "${v:-}" ] && [ -n "${i:-}" ] || continue
		# A disconnected rail reports a negative sentinel, not 0.
		[ "$v" -ge 0 ] && [ "$i" -ge 0 ] || continue
		total=$(( total + v * i / 1000000000000 ))
	done
	if [ "$total" -gt 0 ]; then
		printf '  charge power:    ~%s W through the pumps\n' "$total"
	fi
	v=$(rd "$USB/voltage_now"); i=$(rd "$USB/current_now")
	if [ -n "${v:-}" ] && [ -n "${i:-}" ]; then
		if [ "$v" -lt 0 ] || [ "$i" -lt 0 ]; then
			printf '  buck input:      offline\n'
		else
			printf '  buck input:      %s.%03d V  %s.%03d A\n' \
				"$((v/1000000))" "$(((v/1000)%1000))" \
				"$((i/1000000))" "$(((i/1000)%1000))"
		fi
	fi
	printf '  battery:         %s%%\n' "$(rd "$BAT/capacity")"
}

elevate() {
	if [ "$(id -u)" = "0" ]; then "$@"; else sudo "$@"; fi
}

do_apply()   { elevate "$APPLY" || return 1
               elevate systemctl restart "$UNIT" 2>/dev/null || true
               sleep 2; status_text; }
do_enable()  { elevate mkdir -p "$(dirname "$OPTIN")" && elevate touch "$OPTIN" \
               && elevate systemctl restart "$UNIT" 2>/dev/null || true
               echo "direct-charge opt-in: ON"; }
do_disable() { elevate rm -f "$OPTIN"; elevate systemctl stop "$UNIT" 2>/dev/null || true
               echo "direct-charge opt-in: OFF (stock charging)"; }

menu() {
	while true; do
		clear
		echo "=== Armada EVO 28 W charging ==="
		status_text
		echo
		echo "  1) Re-apply the pack (do this if charging looks stock)"
		echo "  2) Turn direct charge ON"
		echo "  3) Turn direct charge OFF (stock 18 W)"
		echo "  4) Refresh"
		echo "  q) Quit"
		printf 'choice: '
		read -r c
		case "$c" in
			1) do_apply ;;
			2) do_enable ;;
			3) do_disable ;;
			4) : ;;
			q|Q) exit 0 ;;
		esac
		printf '\npress Enter to continue... '; read -r _
	done
}

case "${1:-status}" in
	status)  status_text ;;
	apply)   do_apply ;;
	enable)  do_enable ;;
	disable) do_disable ;;
	menu)    menu ;;
	*)       sed -n '2,12p' "$0"; exit 1 ;;
esac
