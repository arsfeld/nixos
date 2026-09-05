# Goodix 27c6:521d fingerprint on blackbird

**Date:** 2026-09-05
**Host:** blackbird (ASUS ROG Zephyrus G14, dual-boot with Windows)
**Status:** design approved, not yet implemented

## Goal

Fingerprint unlock on blackbird through fprintd/libfprint, targeting sensor firmware
`GFUSB_GM168SEC_APP_10034` — the build the Windows driver uses — so that booting Windows
does not break Linux fingerprint auth.

The success bar is specifically **survives dual-boot**. A driver that works until the next
Windows session and then needs re-flashing does not meet it.

## Non-goals

- Upstreaming a driver to libfprint.
- Eliminating the all-zero PSK. Accepted as a known weakness (see Risk 2, which may force
  us to revisit).
- Any host other than blackbird, any sensor other than `27c6:521d`.

## Background: what is actually on this machine

Findings established during design, recorded here because they cost real time to rediscover.

### The sensor

`27c6:521d` Shenzhen Goodix, USB bus 005, vendor-specific interface class, no kernel
driver bound.

### Why the obvious paths do not work

- **Upstream libfprint** (nixpkgs 1.94.100) lists `{ .vid = 0x27c6, .pid = 0x521d }` in
  `allowlist_id_table` in `libfprint/fprint-list-udev-hwdb.c`, under the comment
  *"Currently known and unsupported devices."* It is explicitly known-broken, not merely
  absent.
- **`pkgs.libfprint-2-tod1-goodix`** ships exactly one driver,
  `libfprint-tod-goodix-53xc-0.0.6.so`, whose udev rules cover `538c`, `533c`, `530c`,
  `5840`. It is the `53xc` family blob and does not touch `521d`.

### The community driver and its two costs

`infinytum/libfprint` branch `unstable` carries a `goodixtls` driver with
`drivers/goodixtls/goodix52xd.c`, whose `id_table` contains `521d`. It is what the AUR
package `libfprint-goodix-521d` builds. Last commit 2021-11-17, based on libfprint 1.94.1.
The PKGBUILD needs `-Wno-incompatible-pointer-types` to build against modern GCC.

Using it as-is costs two things:

1. **A firmware downgrade.** The driver hardcodes
   `#define GOODIX_52XD_FIRMWARE_VERSION ("GFUSB_GM168SEC_APP_10019")`, and
   `goodix-fp-dump`'s `driver_52xd.py` erases and downgrades anything matching
   `GFUSB_GM168SEC_APP_100[0-9]{2}` that is not exactly 10019.
2. **An all-zero session key.** `driver_52xd.py` defines `PSK` as 32 zero bytes and
   `PMK_HASH` as `66687aad…2925`, which is precisely `SHA256(32 zero bytes)`. `write_psk()`
   sends the `PSK_WHITE_BOX` blob (named for Goodix's white-box key format; its contents
   were not decoded here), and then `check_psk()` accepts the result only when the sensor's
   stored PMK hash equals `SHA256(zeros)`. So whatever the blob encodes, the observable
   outcome is that the sensor ends up keyed with the all-zero PSK. The `goodix_52xd_psk_0`
   array in `goodix52xd.h` is that same hash, used driver-side for the identical check.

### The Windows driver — and why it is unusually tractable

`C:\Windows\INF\oem14.inf` is `WbdiUsb.inf`, binding `USB\Vid_27C6&Pid_521D`. Driver
package lives at
`Windows/System32/DriverStore/FileRepository/wbdiusb.inf_amd64_259c2993aea94964/`:

| File | Size | Role |
|---|---|---|
| `wbdi.dll` | 1508840 | UMDF user-mode driver, USB protocol + firmware |
| `GoodixEngineAdapter.dll` | 1175528 | WBF matching engine |
| `SessionService.exe` | 27568 | session detection service |

`DriverVer = 07/20/2021, 3.0.21.280`.

Two properties matter:

- **There is no kernel driver.** The INF declares `UmdfDispatcher=WinUsb`,
  `Include=WINUSB.INF`, `ServiceBinary=%12%\UMDF\wbdi.dll`. Everything runs in user mode
  over WinUSB, so all sensor traffic is ordinary USB bulk transfer submitted from
  userspace.
- **`wbdi.dll` targets firmware 10034, not 10019.** Strings present:
  `GFUSB_GM168SEC_APP_10034`, `MILAN_GM168SEC_IAP_10007`, `MILAN_GM168SEC_IAP_20003`.

That version mismatch — Windows on 10034, the Linux driver demanding 10019 — is the exact
mechanism behind the reflash treadmill people report.

The goodixtls zero PSK does **not** appear in `wbdi.dll`, but the PSK protocol flag
`0xbb020001` appears 3 times. So Windows uses the same PSK subsystem with a different key.
How it obtains that key is the central unknown of this project.

## Approach

Three phases, gated so that nothing is written to the sensor until we have exhausted what
can be learned without writing.

### Phase 0 — Baseline probe (no writes)

**0a. Read sensor state.** A script built on `goodix-fp-dump`'s `goodix.py` / `protocol.py`
calling only `nop()`, `firmware_version()`, and `check_psk()`. It must never call
`erase_firmware()`, `update_firmware()`, or `write_psk()`. Run from a Nix shell providing
`pyusb`, `crcmod`, `pycryptodome`, `crccheck`, `python-periphery`.

Outputs: the firmware version string, and whether the stored PMK hash already equals
`SHA256(zeros)`.

Interpretation:

| Firmware | PSK zeroed | Meaning |
|---|---|---|
| 10034 | no | Windows-provisioned. Expect handshake failure; Phase 2 needed. |
| 10034 | yes | Already zeroed. Driver may work with only the version gate patched. |
| 10019 | yes | Sensor was downgraded previously. |
| `MILAN_*_IAP_*` | n/a | Sensor sits in bootloader; unusable until flashed. |

**0b. Patched driver build.** A Nix derivation for `infinytum/libfprint` @ `unstable` with
two changes: add `-Wno-incompatible-pointer-types`, and widen the firmware gate. The gate is
a single `strcmp(firmware, GOODIX_52XD_FIRMWARE_VERSION)` in `check_firmware_version()` at
`libfprint/drivers/goodixtls/goodix52xd.c:106`, against the literal defined in
`goodix52xd.h`. Prefer relaxing it to a prefix match on `GFUSB_GM168SEC_APP_` over swapping
in a second literal, so a future firmware revision does not require another patch.

**0c. Attempt enroll** from a `nix shell` against the device, not installed system-wide,
with `G_MESSAGES_DEBUG=all`.

This is verified non-destructive, not merely assumed. The `goodixtls` driver contains no
firmware erase or write path at all — only the Python tool flashes. It does contain
`goodix_send_preset_psk_write()` in `goodix.c`, but that function has **no callers**; it is
dead code in the library. `goodix52xd.c` only ever calls `goodix_send_preset_psk_read()`
and `memcmp`s the result against `goodix_52xd_psk_0`, erroring out on mismatch. Worst case
is a failed activation.

**A free diagnostic falls out of this.** The activate state machine checks firmware version
first (`check_firmware_version`, `strcmp` at `goodix52xd.c:106`) and the PSK second
(`ACTIVATE_CHECK_PSK`, `goodix52xd.c:292`). On unpatched code with a 10034 sensor it aborts
at the firmware `strcmp` before ever reading the PSK. Once the gate is widened it proceeds
to `check_preset_psk_read()`, which logs `fp_dbg("Device PSK: 0x%s", psk_str)` — so the run
prints the sensor's **actual stored PMK hash** before failing. That is a read-only answer to
the central unknown of this project, obtained without a VM.

**Exit criteria:** an enroll succeeds (go to Phase 3), or we hold a precise failure point
plus the device's real PMK hash (go to Phase 1).

### Phase 1 — Capture our own failure (no writes)

Record the failing attempt on host `usbmon` bus 5. This is the Linux-side reference trace
that makes the Windows trace diffable. Requires `modprobe usbmon` and debugfs mounted;
both verified working on blackbird.

### Phase 2 — Windows VM capture (only if Phase 0 fails)

**VM.** libvirt domain, Windows 11 evaluation ISO, q35 + UEFI + vTPM via swtpm, disk under
`/var/tmp`. Explicitly **not** a raw-disk boot of the existing `nvme0n1p5` install — that
risks BitLocker, activation churn against different virtual hardware, and corruption if the
partition was hibernated.

**Passthrough.** Sensor attached as a libvirt `<hostdev>` matched on vendor `0x27c6` /
product `0x521d`. Nothing is bound to the device on the host, so no unbind is needed.

**Driver install.** Sideload the extracted `WbdiUsb.inf` plus the three binaries via
`pnputil`. No vendor installer required.

**Capture.** Host-side on `/sys/kernel/debug/usb/usbmon/5u`. QEMU's `usb-host` submits URBs
through host usbfs and usbmon taps at the usbcore layer beneath it, so the host sees every
transfer the guest makes with **zero** capture software in the guest. Three scenarios:
device init and firmware check, Hello enroll, Hello verify.

**Analysis.** Decode using the framing already known from `goodix_proto.c` and
`protocol.py`, focused on the PSK exchange and any version-gated commands. Where the
capture is ambiguous — particularly PSK derivation — use `schlarpc/re-shell` (a Nix-flake
reverse-engineering environment bundling Ghidra, radare2, Frida, mitmproxy) against
`wbdi.dll`.

**This phase is where read-only ends.** The Windows guest may flash the sensor. Writing
10034 serves the goal, but it is still a write, and it requires explicit approval before the
device is attached to a booting VM.

### Phase 3 — NixOS packaging

1. `packages/libfprint-goodix-521d.nix` — the patched fork; haumea auto-loads it.
2. An `fprintd` override consuming it, **scoped to blackbird**. Not a global libfprint
   overlay, which would drag every other host onto a five-year-old fork.
3. `services.fprintd` enabled in `hosts/blackbird/`, with `package` pointed at the override.
   GNOME Settings surfaces enrollment automatically.
4. PAM stays a convenience factor, never sole authentication, given the driver's maturity
   and the zero-PSK weakness.

blackbird is not in tier1, so this stays out of the weekly-deploy path.

## Testing

- **Build gate:** `nix build .#nixosConfigurations.blackbird.config.system.build.toplevel`.
- **Deploy:** `just deploy blackbird` from raider (raider is the deploy driver, and is where
  this work happens).
- **Acceptance:** enroll a finger, `fprintd-verify` passes, then **boot Windows, use Hello,
  boot back to NixOS**, and `fprintd-verify` still passes. That round trip is the entire
  point of the project and requires booting Windows once by hand.

Phases 0 through 2 are investigation; they are validated by their captured output, not by
automated tests. Phase 3 carries the build gate above.

## Error handling and recovery

- Keep both firmware images on hand: the public 10019 image from the `goodix-firmware`
  submodule, and whatever we extract for 10034.
- A failed flash drops the sensor into IAP mode (`MILAN_GM168SEC_IAP_10007`), which
  `driver_52xd.py` recognizes and can re-flash from. This kills the fingerprint reader, not
  the laptop — the sensor is an internal USB device and the machine boots normally without
  it.
- Every flashing operation is gated behind explicit approval, not performed opportunistically.

## Risks and open questions

1. **The 10034 image boundaries in `wbdi.dll` are unconfirmed.** The version string sits at
   `0x1224` inside the known 10019 image, and appears in `wbdi.dll` at `0xdf091` and
   `0xe035f`. Taking `0xdf13b` as an image base yields a 25200-byte candidate whose
   per-2KB similarity to 10019 is 56% around the header table and roughly 4% elsewhere —
   consistent with either a genuinely different build or a non-contiguous/compressed
   layout. Unresolved. It only blocks us if we end up needing to flash 10034 ourselves.

2. **The PSK, not the firmware, is the real threat to the goal.** If Windows re-provisions a
   non-zero PSK on every boot, matching firmware alone will not deliver a dual-boot-stable
   setup: we would have to re-zero the key after each Windows session. That is a cheaper
   treadmill than reflashing but still a treadmill, and it would mean the stated success bar
   is unreachable without solving PSK derivation properly. Phase 0c gives the first read on
   it for free by logging the device's stored PMK hash; Phase 2 exists to explain how
   Windows arrives at that value.

3. **The fork is five years stale**, libfprint 1.94.1 against nixpkgs' 1.94.100. Pinning it
   is an ongoing maintenance cost, and each nixpkgs bump is an opportunity for it to break.

4. **Sideloading the driver in the VM may require test-signing mode**, since the package is
   being installed outside its original catalog chain.

## Verified environment facts (blackbird)

| Requirement | State |
|---|---|
| `/dev/kvm` | present |
| qemu-system-x86_64, virsh, virt-install | installed |
| vTPM (`swtpm`) | enabled via `constellation.virtualization` |
| `usbmon` | loads; exposes `5u` for the sensor's bus |
| sensor driver binding | none — clean passthrough |
| RAM / disk | ~20 GB free / 102 GB on `/var/tmp` |
| Windows partition | `nvme0n1p5`, NTFS, 425.6 GB |

## Findings (2026-09-05)

Read-only probe (`nop()`, `firmware_version()`, `preset_psk_read()` only) run against the
521d sensor on blackbird via `goodix-fp-dump`, over a nix shell providing pyusb, crcmod,
crccheck, pycryptodome, python-periphery, and spidev:

```
FIRMWARE: GFUSB_GM168SEC_APP_10034
PSK_FLAGS: 0xbb020001
PSK_HASH: 126770ba77304106160859262e4d0a2ffed13ed794fc703023111345fc746dd0
PSK_IS_ZERO: False
```

The sensor is running application firmware (not the `MILAN_GM168SEC_IAP_*` bootloader), and
its stored PSK hash is non-zero — this is the expected/predicted outcome from Task 1's
brief, not the bootloader-recovery case. Both facts Task 3 branches on are now established:
`FIRMWARE = GFUSB_GM168SEC_APP_10034`, `PSK_IS_ZERO = False`.

### Task 3: patched-driver enroll attempt — OUTCOME 2 (`Invalid device PSK`)

Built the `infinytum/libfprint` `unstable` fork on blackbird in `/tmp/lfp-fork`, with the
firmware gate in `libfprint/drivers/goodixtls/goodix52xd.c` widened from an exact `strcmp`
against `GOODIX_52XD_FIRMWARE_VERSION` to `strncmp(firmware, "GFUSB_GM168SEC_APP_", 19)`
(confirmed present at line 106 post-build). The plain `nix shell nixpkgs#glib …` one-liner
from the brief does not work as written — `nix shell` does not run package setup hooks, so
`PKG_CONFIG_PATH` never gets populated and `meson setup` fails at `Dependency "glib-2.0" not
found`. Worked around with an ad hoc `nix develop` flake (`pkgs.mkShell` with the same
package list as `nativeBuildInputs`/`buildInputs`), which does wire `PKG_CONFIG_PATH` via
setup hooks; build then succeeded cleanly (`ninja -C build`, 96/96, producing
`build/examples/enroll`). No production module or committed file was changed by this
workaround — it only affects how the disposable `/tmp/lfp-fork` build tree was compiled.

Ran `sudo G_MESSAGES_DEBUG=all LIBUSB_DEBUG=3 ./build/examples/enroll`, feeding it a newline
(continue) and `1` (left index finger) on stdin so it would proceed past the interactive
prompts, output captured to `/tmp/enroll.log` on blackbird and retrieved to
`$SCRATCH/captures/enroll-baseline.log`. The driver claimed the device
(`Selected device 0 (Goodix TLS Fingerprint Sensor 52XD) claimed by goodixtls52xd driver`),
opened it, and reached `ACTIVATE_NUM_STATES` state 4 (`ACTIVATE_CHECK_PSK`) in well under a
second — it never reached the finger-scan stage, so no physical touch was needed and the
`timeout 60` guard was never a factor:

```
(process:45994): libfprint-goodixtls52xd-DEBUG: 13:47:37.016: Device firmware: "GFUSB_GM168SEC_APP_10034"
(process:45994): libfprint-goodixtls52xd-DEBUG: 13:47:37.045: Device PSK: 0x126770ba77304106160859262e4d0a2ffed13ed794fc703023111345fc746dd0
(process:45994): libfprint-goodixtls52xd-DEBUG: 13:47:37.045: Device PSK flags: 0xbb020001
(process:45994): libfprint-SSM-DEBUG: 13:47:37.045: [goodixtls52xd] SSM ACTIVATE_NUM_STATES failed in state 4 with error: Invalid device PSK: 0x126770ba77304106160859262e4d0a2ffed13ed794fc703023111345fc746dd0
(process:45994): libfprint-goodixtls52xd-CRITICAL **: 13:47:37.045: failed during activation: Invalid device PSK: 0x126770ba77304106160859262e4d0a2ffed13ed794fc703023111345fc746dd0 (code: 35)
(process:45994): libfprint-WARNING **: 13:47:37.045: Enroll failed with error Invalid device PSK: 0x126770ba77304106160859262e4d0a2ffed13ed794fc703023111345fc746dd0
```

**Classification: Outcome 2.** The firmware gate now passes (`Device firmware:
"GFUSB_GM168SEC_APP_10034"` logged, no `Invalid device firmware` anywhere), the driver
reached `ACTIVATE_CHECK_PSK`, and enrollment failed there on the PSK comparison — exactly
the expected/predicted case, not a failure of this task.

**PMK hash cross-check:** the logged `Device PSK: 0x126770ba77304106160859262e4d0a2ffed13ed794fc703023111345fc746dd0`
is identical (byte-for-byte, modulo the `0x` prefix) to Task 1's read-only-probe
`PSK_HASH: 126770ba77304106160859262e4d0a2ffed13ed794fc703023111345fc746dd0`. Same value,
same PSK flags (`0xbb020001`) — the two independent code paths (read-only probe vs. the
patched driver's real `ACTIVATE_CHECK_PSK` comparison) agree. This is the confirmed real
stored PMK hash on this sensor, still not the all-zero key and still matching none of the
29 published Goodix PSK constants (per Task 2's finding). No firmware write or PSK write
was attempted or is needed to reach this result — `goodix_send_preset_psk_write()` was not
called; only `goodix_send_preset_psk_read()` ran (visible above at command `0xe4`).

**Branch:** proceed to Task 4 (Task 7 is skipped — enroll did not succeed).

**Post-run re-probe (empirical no-change confirmation):** re-ran the Task 1 read-only probe
(`nop()`, `firmware_version()`, `preset_psk_read()` only) against the sensor after the
enroll attempt above:

```
FIRMWARE: GFUSB_GM168SEC_APP_10034
PSK_FLAGS: 0xbb020001
PSK_HASH: 126770ba77304106160859262e4d0a2ffed13ed794fc703023111345fc746dd0
PSK_IS_ZERO: False
```

Unchanged on every field versus Task 1's original probe and versus the value the patched
driver read during the enroll attempt. Confirms empirically, not just by code inspection,
that the sensor's firmware and stored PSK were not modified.
