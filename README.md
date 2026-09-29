# pocketevo-charging

Restore **28 W direct charging** on an AYANEO Pocket EVO running a stock
[armada-os](https://github.com/armada-os/armada) image — without rebuilding or
replacing the OS image.

> ⚠️ **Experimental. Read the safety notes.** This replaces the kernel's
> Qualcomm battery-manager module on a running system and pushes a PPS adapter
> to 10.5 V × ~3.06 A. It is not endorsed by or affiliated with armada-os.

## Why this exists

Armada OS is a bootc/ostree image. Every `bootc upgrade` replaces `/usr` and
`/boot` wholesale, so anything shipped inside the image is discarded on each
update — which is why the usual approach (fork the image, carry the patches,
rebuild and republish) means rebuilding a whole OS image for every upstream
change.

`/etc` and `/var`, however, **survive updates**. So this pack keeps the charging
stack in `/var`, wires it up from `/etc`, and re-applies it on every boot. An
ordinary image update needs no action at all. Nothing here writes to `/usr`,
`/boot`, or the device tree.

## What it installs

| Layer | Artifact | Location |
|---|---|---|
| Charge pumps | `hl7139_evo.ko` | `/var/armada/charging/modules/<kver>/` |
| PPS + input-current control | patched `qcom_battmgr.ko` | same |
| Charge policy | `armada-pocketevo-charge-policy` | `/var/armada/charging/bin/` |
| Re-apply at boot | `armada-charging-pack.service` | `/etc/systemd/system/` |
| Re-apply on plug-in | `70-armada-charging-pack.rules` | `/etc/udev/rules.d/` |
| Opt-in flag | `pocketevo-direct-charge` | `/etc/armada/experimental/` |

The EVO has **two** HL7139 charge pumps (i2c 0x5f master, 0x5e slave). The stock
armada kernel ships an HL7139 driver, but it targets the Mangmi Pocket Max: one
pump, a fixed supply name, and the i2c driver name `hl7139-charger`. This pack
builds its own driver out-of-tree as `hl7139-evo` so the two can coexist.

The pumps have no device-tree nodes in the stock image, and the DTBs are built
without `__symbols__`, so a runtime overlay cannot reference `&i2c_hub_2`. They
are instantiated through the i2c `new_device` interface, and the supplies are
named by address: `hl7139-5f` and `hl7139-5e`.

## Requirements

- AYANEO Pocket EVO on a stock armada-os image whose kernel matches the bundle
  you download (see *Kernel versions* below).
- A **PD-PPS capable** charger. Without PPS the policy refuses to engage by
  design and charging stays on the stock ~18 W path — this is a guard, not a
  failure.

## Install

Download `charging-pack-<kernelrelease>.tar.gz` from the
[Releases](../../releases) page, copy it to the device, and run:

```sh
tar -xzf charging-pack-<kver>.tar.gz
cd bundle
sudo ./install.sh
```

`install.sh` is idempotent. It installs into `/var/armada/charging`, enables the
services, opts in to direct charging, and adds a **28W Charging** desktop icon
(Desktop Mode).

## Re-enabling after an OS update

**It is automatic.** `armada-charging-pack.service` runs on every boot and
re-establishes the modules; `armada-pocketevo-charge-policy.service` starts
after it once both pumps exist and the opt-in flag is present. Because `/etc`
and `/var` survive updates, a normal `bootc upgrade` needs no action.

To check or force it:

```sh
sudo /var/armada/charging/bin/charging-control.sh status
sudo /var/armada/charging/bin/charging-control.sh apply     # force re-apply
sudo /var/armada/charging/bin/charging-control.sh enable    # or disable
```

Or use the **28W Charging** icon in Desktop Mode, which opens the same menu.

### Kernel versions

The modules are keyed to the kernel release (`uname -r`). If an update bumps the
kernel before a matching bundle exists, the boot unit records

```
degraded: no charging module pack for kernel <ver>
```

in `/var/armada/charging/status` and charging falls back to the stock ~18 W buck
charger. It does **not** try to load a module built for another kernel, and it
does not block the boot. Watch the Releases page for a rebuild.

## Verifying

```sh
# patched battery manager? 644 = patched, 444 = stock
stat -c %a /sys/class/power_supply/qcom-battmgr-usb/voltage_now

# pumps present?
ls /sys/class/power_supply/ | grep hl7139

# is PPS available on this charger?
grep -o '\[PD_PPS\]' /sys/class/power_supply/qcom-battmgr-usb/usb_type

# live session
systemctl status armada-pocketevo-charge-policy
journalctl -u armada-pocketevo-charge-policy -f
```

The policy logs one line per sample with the requested PPS voltage, source and
device power, and temperatures:

```
pocketevo-charge: SOC=69% request=10500000uV input=3063500uA source=32166mW device=27534mW battery=4233007uV/5053836uA temps=300/573/563dC
```

## Building

Needs an aarch64 cross toolchain plus the usual kernel build dependencies
(`bc`, `bison`, `flex`, `libelf-dev`, `libssl-dev`, and **pahole ≥ 1.31**,
because the armada config enables `CONFIG_DEBUG_INFO_BTF`).

```sh
./build/build-pack.sh
```

The script fetches armada's `packages/kernel` at `ARMADA_REF` (default `main`),
applies `patches/*.patch` after armada's own series, builds the kernel, builds
`driver/` out-of-tree against it, strips BTF, and writes
`dist/charging-pack-<kver>.tar.gz`. Nothing from armada is vendored here.

`deploy.sh <bundle.tar.gz> <user@host>` copies a bundle to a device and runs the
installer.

### Two things that will bite you

**Split BTF must be stripped.** An in-tree module carries `.BTF` + `.BTF.base`.
At load time `btf_module_notify()` validates the base against the *running*
kernel's vmlinux BTF and refuses the module when the base IDs do not line up —
which they never do for a module built elsewhere:

```
failed to validate module [qcom_battmgr] BTF: -22
insmod: ERROR: could not insert module qcom_battmgr.ko: Invalid parameters
```

Module BTF only feeds BPF introspection, so `build-pack.sh` removes it with
`objcopy`. With no `.BTF` section the kernel skips validation entirely.
(Out-of-tree modules get no `.BTF.base`, which is why the driver never hit this.)

**Never `lsmod | grep -q` under `set -o pipefail`.** `grep -q` exits on the first
match and SIGPIPEs `lsmod`, so the pipeline reports failure even though the
module was found. The scripts use
`grep -q "^$1 " /proc/modules` instead.

## Rolling back

```sh
sudo /var/armada/charging/bin/charging-control.sh disable   # stock charging
sudo systemctl disable --now armada-charging-pack.service armada-pocketevo-charge-policy.service
sudo rm -rf /var/armada/charging
sudo rm -f /etc/systemd/system/armada-charging-pack.service \
           /etc/systemd/system/armada-pocketevo-charge-policy.service \
           /etc/udev/rules.d/70-armada-charging-pack.rules
sudo systemctl daemon-reload
```

## Safety and known gaps

- **This replaces `qcom_battmgr` on a live system.** The swap happens at boot
  (and on plug-in), and if the patched module fails to load the installer
  restores the stock one.
- **The fault IRQ is not wired.** The driver's fault handler (VIN/VBAT OVP, OCP,
  flying-cap short, thermal shutdown → disable charge) needs `intr-gpios`. The
  pump interrupt pins have no device-tree nodes, and their stock pin state is
  GPIO input with a pull-down while the driver requests a falling edge — so the
  handler could not fire reliably. Chip-level protection and the policy's
  independent guards (VIN range, VBUS coherence, current limits) still apply.
  Closing this properly requires a DTB change.
- **Charger compatibility.** The policy ramps the PPS request to 10.5 V at up to
  ~3.06 A. Adapters that advertise PPS but misbehave at those points are the
  main risk. The policy verifies the measured rail against the request and tears
  the session down on mismatch.
- **A future armada image that ships its own EVO pump driver or
  `armada-pocketevo-charge-policy.service` will collide with this pack.**
- Measured on one EVO: ~32 W drawn from the adapter, ~27 W into the device
  (stock path ~17.7 W).

## Credits

- The charge-pump register mapping and the original HL7139 driver lineage come
  from the Mangmi Pocket Max stock kernel / HiSilicon `hwpower` GPL driver, via
  armada's vendored
  `0063_Mangmi-Pocket-Max-HL7139-charge-pump.patch`.
- The userspace charge policy and the `qcom_battmgr` PPS/input-current work are
  from [@jesherman](https://github.com/jesherman)'s upstream PRs
  ([armada#258](https://github.com/armada-os/armada/pull/258),
  [armada-packages#35](https://github.com/armada-os/armada-packages/pull/35)).
- The battery-manager patches in `patches/` are adapted from that work for this
  delivery mechanism.

## License

GPL-2.0-only. See [LICENSE](LICENSE).
