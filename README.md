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
| Kernel identity gate | `charging-kernel-fingerprint.sh` | `/var/armada/charging/bin/` |
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

### Kernel versions, and the identity gate

The modules are keyed to the kernel release (`uname -r`), but **the release does
not identify the kernel**. armada has shipped at least two different 7.2.6 kernels
built from different patch sets, and `uname -r` reports the same `7.2.6` for both.
With `CONFIG_MODVERSIONS` off there is no symbol CRC for the kernel to check
either, so a module built against the wrong build loads cleanly and the pack
reports `ok` while running code that was never built for that kernel.

That is not hypothetical. On 2026-10-01 the unit moved from image
`20260928.311ed3b` to `20261001.72f2a63`, kept kernel release `7.2.6`, and the pack
re-applied against a kernel it had never been built for — reporting success.
Nothing had verified that; the pack simply never looked.

So the pack fingerprints the **interface it actually compiles against** — every
module armada ships for the power-supply subsystem — and refuses to load unless
that set is what was present when the pack was validated on this device.

#### Why not fingerprint the kernel itself

Because it would be a false alarm every time. Measured 2026-10-02 across exactly
that update, by building both trees with the same toolchain:

| artifact | `311ed3b` build | `72f2a63` build |
|---|---|---|
| stock `qcom_battmgr.ko` | `e55f2670…` | `e55f2670…` identical |
| this pack's patched `qcom_battmgr.ko` | `594c30ba…` | `594c30ba…` identical |
| `vmlinuz` | `35aa183d…` | `5f109746…` **changed** |

armada added three kernel patches in that window — an arm64 unaligned-atomics fix,
a drm/msm submitqueue change and an input/rsinput calibration change — so `vmlinuz`
changed, while the battery manager and its entire subsystem came out byte-identical.
A gate keyed on `vmlinuz` would have refused a pack that was provably still correct,
every few days, at the cost of a 40-minute kernel rebuild. Keying it on the subsystem
refuses exactly when the interface really moves.

That measurement is also the answer to the obvious question about the past mismatch:
it was benign, and now it is *known* to have been benign rather than assumed — the
pack's module was the same bytes in both builds.

#### What it does

- `install.sh` records the baseline, and refuses to install when the bundle was built
  from a different armada commit than the image the device is running. Override with
  `sudo ./install.sh --force` if you have a specific reason.
- `charging-pack-apply.sh` only ever compares. It deliberately will **not** adopt a
  new kernel on its own, because the first boot after an update would then silently
  bless modules that were never built for that kernel — the exact failure above.
- On a mismatch it writes

  ```
  degraded: image kernel changed since this pack was validated (<old> -> <new>);
  refusing to load modules built for another kernel -- rebuild the pack for this
  kernel and re-run install.sh
  ```

  to `/var/armada/charging/status`, dumps recorded-vs-running into
  `/var/armada/charging/notes`, and falls back to the stock ~18 W buck charger. It
  does not block the boot.

Check the verdict without loading anything:

```sh
sudo /var/armada/charging/bin/charging-control.sh status    # "kernel identity:" line
/var/armada/charging/bin/charging-kernel-fingerprint.sh check; echo $?  # 0 match, 1 changed, 2 no baseline, 3 cannot fingerprint
```

`ARMADA_CHARGING_SKIP_FINGERPRINT=1` bypasses the gate. That is a recovery hatch,
not something to leave set.

A release bump with no matching bundle still records
`degraded: no charging module pack for kernel <ver>` and degrades identically.
Watch the Releases page for a rebuild.

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

Iterating on the payload — the installer, the units, the policy, the fingerprint
helper — does **not** need a kernel rebuild, because the kernel build spends ~40
minutes before it ever looks at `payload/`:

```sh
./build/make-bundle.sh    # re-stage and repack from the last build's modules
```

`build-pack.sh` calls that same script for its final phase, so there is exactly one
implementation of what goes into the bundle.

Builds are reproducible modulo one detail: three independent builds of the
in-tree `qcom_battmgr.ko` produced a byte-identical sha256, while the
out-of-tree `hl7139_evo.ko` embeds the absolute directory it was built in and so
differs between build paths only. The whole-kernel tarball is not reproducible —
it carries timestamps and is not meant to be compared byte for byte.

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

## Tests

```sh
./tests/gate-test.sh
```

Drives `charging-pack-apply.sh --check` against a fake kernel tree and asserts the
identity gate refuses when the kernel is rebuilt, when only the stock
`qcom_battmgr.ko` changes, when only `.armada-source` changes, when a fingerprinted
file disappears, and when no baseline exists at all — plus that it opens on a
matching kernel and honours the bypass. No root, no device and no module loading:
`--check` stops immediately after the gate.

It earned its keep on the first run. The initial gate compared every non-comment
line of the fingerprint file, including the `image=` and `armada_commit=`
provenance lines, which the live fingerprint never emits — so it would have
degraded unconditionally on the device, silently pinning the unit to 18 W.

```sh
./tests/charger-restore-test.sh
```

Drives the cleanup and the policy's idle path against a fake power-supply tree,
so it needs no root, no device and no hardware. It covers the 2026-10-02
regression end to end: the cleanup must restore the PPS request and release the
13 mA handoff limit **even when VBUS is already absent**, the idle policy must
re-assert sane charger values when — and only when — the Qualcomm path is online
and drawing nothing, and neither may act while a pump is live, while the
charger is healthy, or with no cable attached.

```sh
./tests/session-simulation-test.sh
```

Drives **whole sessions** through the policy's own sample hook against a fake
power-supply tree — the only way to exercise the guards that end a session. It
covers the `no-delivery` guard firing after 30 s of zero current, a 40-sample
stall *not* firing it, the endpoint guard ending cleanly without latching, and
the VIN-headroom regulator holding the request under 10.1 V against an adapter
that runs 400 mV above it.

## Charger handoff guards

Three guards exist specifically because of the 2026-10-02 failure, where the
device sat plugged in drawing nothing while the battery fell from 85% to 74%
over 73 minutes.

- **The cleanup always restores, cable or no cable.** The PPS request and the
  13 mA handoff limit live in the charger firmware and outlive a cable pull, so
  skipping the restore strands the *next* plug-in at a 5 V / 0 A operating
  point. On the offline path the writes are best-effort and a refusal is not a
  fault — there is nothing to charge at that moment either way.
- **The watch loop ends a session that is not delivering power.** Every other
  guard in `direct_session` checks *state* (pump flags, health, rail voltage);
  `no-delivery` is the only one that checks whether current is actually moving.
  60 consecutive samples — 30 s — below 200 mA ends the session, so the
  Qualcomm path takes over instead of idling silently for hours.
- **The idle policy repairs a dead charger.** When, and only when, the USB
  supply is online, both pumps are off, the battery is discharging and the
  charger is drawing under 100 mA, the policy re-asserts `9600000uV` /
  `3000000uA`, rate-limited to once a minute. Without it a stuck charger stays
  stuck until a human notices, because `eligible()` requires
  `battery/status = Charging` and a dead charger never reports it.

`no-delivery` deliberately does **not** latch a fault: the cleanup has already
handed the charger back, so the session ends, the policy backs off for 120 s to
let the stock path take over, and direct charge is free to start again. A latch
here would turn a recoverable stall into a "unplug the charger" prompt.

- **The request is regulated against the measured rail, not just the request.**
  Nothing else watches the rail, so the integrator — which raises the request
  whenever combined pump input is under 3.08 A, a figure this adapter never quite
  reaches (~3.05 A) — winds up to the 10.5 V clamp and saturates there. Under
  falling end-of-charge load the adapter holds its operating point a few hundred
  mV *above* the request, the measured VIN crosses the 10.5 V pump ceiling, and
  the VIN guard ends a perfectly healthy session with a latched "unplug the
  charger" fault. On 2026-10-02 that killed a clean 32 W session at SOC 88% —
  the same ending the 2026-09-29 session had. Above 10.4 V the request now drops
  200 mV per sample, and 100 mV above 10.3 V, ahead of every other regulation
  term. The VIN guard is a backstop again, not a routine end-of-charge event.

The full failure analysis, including what could **not** be established, is in
[`docs/incident-2026-10-02.md`](docs/incident-2026-10-02.md).

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
- **Kernel drift is gated; nothing else is.** The identity gate covers the
  power-supply subsystem — see "Kernel versions, and the identity gate" above. If an
  image update changes something *else* about charging (a unit, a firmware config,
  the DTS, the in-tree pump driver) without touching that subsystem, the gate stays
  quiet by design and this pack keeps loading.
- **The fault IRQ is not wired.** The driver's fault handler (VIN/VBAT OVP, OCP,
  flying-cap short, thermal shutdown → disable charge) needs `intr-gpios`. The
  pump interrupt pins have no device-tree nodes, and their stock pin state is
  GPIO input with a pull-down while the driver requests a falling edge — so the
  handler could not fire reliably. Chip-level protection and the policy's
  independent guards (VIN range, VBUS coherence, current limits) still apply.
  The fix belongs upstream: armada carries the EVO device tree at
  `packages/kernel/dts/qcs8550-ayaneo-pocketevo.dts` (with a `.patch` beside it),
  so the pump nodes are a PR to armada rather than a local overlay — which also
  cannot work here, since the shipped DTBs are built without `__symbols__` and
  cannot be overlaid at runtime.
- **Upstream collision risk — checked clear as of `72f2a63`.** A future image that
  ships its own EVO pump driver, an `armada-pocketevo-charge-policy` unit, or a
  `sm8550/ayaneo/pocketevo/battmgr.jsn` would fight this pack. As of 2026-10-02
  none exist: no colliding unit or udev rule name, no userspace `hl7139`
  reference, and no EVO `battmgr.jsn` — the EVO is the one SM8550 board without
  one. The kernel gate will not catch this class of change, so re-check before
  rebasing on a new image.
- **Charger compatibility.** The policy ramps the PPS request to 10.5 V at up to
  ~3.06 A. Adapters that advertise PPS but misbehave at those points are the
  main risk. The policy verifies the measured rail against the request and tears
  the session down on mismatch.
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
