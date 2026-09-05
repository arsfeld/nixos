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

### Task 4A: offline Windows PSK search — preimage NOT FOUND; one DPAPI-wrapped key found, scope uncertain

Mounted `/dev/nvme0n1p5` read-only (`ro,noatime`, confirmed via `mount`), copied six target
paths off byte-for-byte (sizes verified to match the mounted source exactly), then unmounted
immediately. No other part of the 425 GB partition was touched or enumerated.

**Sliding-window preimage search — negative, precisely.** Every 32-byte window of every
byte of the following 8 files was SHA256'd and compared against the target PMK hash
`126770ba77304106160859262e4d0a2ffed13ed794fc703023111345fc746dd0`. No match anywhere
(~111.1 MB scanned in total):

| File | Size (bytes) | Result |
|---|---:|---|
| `Windows/System32/config/SYSTEM` | 16,252,928 | not found |
| `Windows/System32/config/SOFTWARE` | 94,633,984 | not found |
| `Windows/System32/WinBioDatabase/449B518E-CAE1-49FB-9A52-376E26E8546D.DAT` | 75,632 | not found |
| `Windows/System32/WinBioDatabase/51F39552-1075-4199-B513-0C10EA185DB0.DAT` | 1,144 | not found |
| `ProgramData/Goodix/CaptureMatchTime.log` | 17,106 | not found |
| `ProgramData/Goodix/engineadapter-new.log` | 354 | not found |
| `ProgramData/Goodix/goodix.dat` | 154,668 | not found |
| `ProgramData/Goodix/wbdi-new.log` | 10,266 | not found |

Directory listing of `WinBioDatabase/`, taken while mounted, before copying, confirms the
two `.DAT` files above are its entire contents (no other template-store file was missed):

```
drwxr-xr-x 1 root root    4096 May  7 19:01 .
drwxr-xr-x 1 root root 1048576 May 21 04:16 ..
-rwxr-xr-x 1 root root   75632 May  7 19:01 449B518E-CAE1-49FB-9A52-376E26E8546D.DAT
-rwxr-xr-x 1 root root    1144 May  4 21:38 51F39552-1075-4199-B513-0C10EA185DB0.DAT
```

This rules out the PSK (or its SHA256 preimage) being present **verbatim** anywhere in the
SYSTEM/SOFTWARE hives, the WinBio template store, or the Goodix ProgramData tree — combined
with Task 2's identical negative over `wbdi.dll`/`GoodixEngineAdapter.dll`/`SessionService.exe`,
that is every file this project has reason to suspect, all negative. The PSK is not stored
in the clear anywhere examined.

**Registry inspection — the Goodix keys are minimal; one WinBio value is DPAPI-wrapped, of
uncertain scope.**

- `HKLM\System\CurrentControlSet\Control\Goodix\FP` (only one ControlSet exists —
  `ControlSet001`, confirmed via hive root listing) contains exactly the 8 values
  `WbdiUsb.inf` is documented to create (`EnableRemoteWakeup`, `MSOnePressTimeOut`,
  `S0IdleTimeout`, `S3OnePressTimeOut`, `SubmitNeedDelay`, `SupportCMDOKBSSO`,
  `SupportECSSO`, `SupportPBSSO`) — all DWORDs, nothing beyond that set.
- `HKLM\SOFTWARE\Goodix\FP\SessionDetection` exists with a single DWORD
  (`SessionDetection=6`) — no binary values.
- `HKLM\System\CurrentControlSet\Enum\USB\VID_27C6&PID_521D\6&13c452c7&0&3` is standard PnP
  device-instance metadata (hardware IDs, driver GUID, security descriptor, WinBio
  `Configurations\0` subkey naming `DatabaseId=449B518E-CAE1-49FB-9A52-376E26E8546D`, which
  matches one of the two copied `.DAT` files). No 32- or 96-byte blob here.
- **`HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WinBio\SensorInfo\449b518e-cae1-49fb-9a52-376e26e8546d\BioServiceKey`
  is a 262-byte `REG_BINARY` value that parses, byte-for-byte with nothing left over, as a
  well-formed Windows DPAPI blob** (`CRYPTPROTECT_DATA` structure: version 1, provider GUID
  `df9d8cd0-1501-11d1-8c7a-00c04fc297eb`, master-key GUID `b1023ba8-051f-486d-972f-0136ccab9b36`,
  `CALG_AES_256` / `CALG_SHA_512`, 32-byte salt, 32-byte HMAC salt, a **48-byte ciphertext**,
  and a 64-byte HMAC-SHA512 signature). Under PKCS7/AES-CBC a 48-byte ciphertext corresponds
  to any plaintext from 32 to 47 bytes (padding is always 1-16 bytes) — a 32-byte PSK is one
  of 16 equally-consistent plaintext lengths, not something the size alone singles out.
- Both `WinBioDatabase\*.DAT` files (the template store) open with the *same* DPAPI provider
  GUID and the *same* master-key GUID (`b1023ba8-051f-486d-972f-0136ccab9b36`) as
  `BioServiceKey` — the fingerprint templates and the service key are protected under the
  identical DPAPI master key. This is the strongest single clue to what `BioServiceKey`
  actually is, and it points away from the device-level PSK: the value lives under
  *Microsoft's* `WinBio\SensorInfo\<GUID>` tree (not under the vendor's `Goodix\FP` key),
  is named `BioServiceKey` rather than anything PSK-specific, and is wrapped under the exact
  master key that also protects the enrolled-template database. The more natural reading is
  that `BioServiceKey` is the **WinBio subsystem's own key for the template store** — a
  key WinBio's framework manages per-sensor to protect enrolled biometric data at rest — not
  the vendor-specific PSK used in the raw USB/TLS handshake with the sensor hardware. That
  device-level PSK, if Windows-side at all, would more plausibly live inside a vendor-owned
  structure (under `Goodix\FP`, or inside `goodix.dat`/`SessionService`'s own state), none of
  which showed any DPAPI or other wrapping marker. Treat the "`BioServiceKey` is the PSK"
  hypothesis and the "`BioServiceKey` is the template-store key" hypothesis as live
  alternatives, with the evidence here favoring the latter, not the former.
- No second DPAPI blob (searched for the provider-GUID byte pattern across the full
  SOFTWARE hive export) exists anywhere else. `BioServiceKey` is the only such value found in
  the registry — which cuts both ways: it's the only Windows-side wrapped-key candidate at
  all, but nothing here demonstrates it specifically wraps the device PSK rather than
  template data.

**Driver's own log — names DPAPI/SGX-related symbols, but the signal is weaker than it looks.**
`ProgramData/Goodix/wbdi-new.log` (source-level debug log, 38 lines) shows 6 repeated
failures, each a 3-line group:

```
[pskunify.c][GfUnsealData            :0256] >> CryptUnprotectData failed, error: -2146893813
[pskunify.c][PresetPskIsVaildG       :0483] >> gf_sgx_unseal_data failed with error ffffffff
[  geneva.c][ProcessPsk              :1231] >> production_check_psk_is_valid failed with ret:0x1.
```

`-2146893813` is `0x8009000B` (`NTE_BAD_KEY_STATE`), a standard DPAPI/CAPI error. By its name,
`PresetPskIsVaildG` is testing a *preset* (factory-default) PSK candidate, not necessarily
the machine's real enrolled PSK, and this log excerpt does not establish that either call is
operating on `BioServiceKey` specifically — that link is inferred, not shown. The
`gf_sgx_unseal_data` failure is weaker evidence still: blackbird is an AMD Ryzen machine
(ASUS ROG Zephyrus G14), which has no Intel SGX, so that call was near-certain to fail
regardless of the sensor's real state — most likely a trivial unsupported-platform no-op,
carrying little or no information about which unwrap path is actually used for the real PSK.
What the log does establish with more confidence is simply that `pskunify.c`/`geneva.c`
exist in the driver and reference both `CryptUnprotectData` and an SGX-sealing call
somewhere in its logic — worth treating as speculative/circumstantial context, not
corroboration of the DPAPI hypothesis. The exact function/file symbols (`GfUnsealData`,
`PresetPskIsVaildG`, `ProcessPsk`, `production_check_psk_is_valid`, files
`pskunify.c`/`geneva.c`) are still useful search targets for Task 6 (Ghidra) against
`wbdi.dll` if it goes ahead — those symbols were not part of Task 2's search target list.
- `ProgramData/Goodix/goodix.dat` (154,668 bytes) opens with a `NLVFO` magic and is otherwise
  high-entropy binary with no readable strings — consistent with an opaque/encrypted vendor
  data file, not further identified; it was covered by the negative preimage search above.

**Conclusion.** The offline, read-only search is a definitive negative for a verbatim PSK or
its preimage — 111 MB across 8 targeted files, every 32-byte window tested, no hit
(directory listings confirm full file-set coverage of `WinBioDatabase/` and
`ProgramData/Goodix/`). The registry inspection found exactly one Windows-side wrapped-key
candidate, `BioServiceKey` — but the evidence (its location under Microsoft's `WinBio`
tree rather than `Goodix\FP`, its generic name, and its shared master-key GUID with the
template database) more plausibly makes it the **WinBio template-store key**, not the
vendor's device PSK, so this negative should **not** be read as "the PSK is confirmed
DPAPI-wrapped." It remains an open, unresolved possibility rather than an established one.
Decrypting `BioServiceKey` would require the DPAPI master key file for master-key GUID
`b1023ba8-051f-486d-972f-0136ccab9b36` (normally under a user profile's
`AppData\Roaming\Microsoft\Protect\<SID>\`, SID `S-1-5-21-3670928780-1278317118-3340432749-1001`
per the WinBio `AccountInfo` enrollment) plus that user's Windows logon credential to unlock
it — both outside this task's scope and not fetched. If pursued, that path most likely
recovers fingerprint template data rather than the device PSK, based on the reasoning above;
it is noted here as a possible, but unconfirmed and now de-prioritized, follow-up rather
than a clear cheaper alternative to Tasks 4-6. **Tasks 4, 5, and 6 remain necessary** as
originally planned.

### Task 4B: zero-PSK write attempt — device REJECTED the write; no corruption; STOPPED per brief

User approval recorded 2026-09-05 for exactly one operation: `preset_psk_write` provisioning
the all-zero PSK, guarded by firmware assertions on both sides. Wrote
`$SCRATCH/gfd/write_zero_psk.py` on blackbird's `/tmp/gfd` byte-for-byte per the brief (diffed
against the source before running; zero differences), calling only `nop()`,
`firmware_version()`, `preset_psk_read()`, and the single `preset_psk_write(0xbb010003,
PSK_WHITE_BOX, 114, 0, bytes.fromhex("56a5bb956b7c8d9e0000"))` — the exact argument order
from upstream `driver_52xd.write_psk()`, confirmed by reading that function on blackbird
before running anything. `driver_52xd.main()`, `erase_firmware`, `update_firmware`,
`write_firmware`, and `mcu_erase_app` were never imported or called.

**Environment note (not a device issue):** the brief's literal `sudo NIX_PATH=... nix shell
...` failed before touching the device (`error: file 'nixpkgs' was not found in the Nix
search path`) — `sudo` does not accept a bare `VAR=val` prefix as an env assignment on this
host. This is the identical tooling issue already hit and fixed in Task 3's post-run
re-probe; applied the same already-established fix (`sudo env NIX_PATH=nixpkgs=flake:nixpkgs
nix shell ...`) with no change to the script or the device operation.

**Result — the write returned `False`:**

```
BEFORE firmware: GFUSB_GM168SEC_APP_10034
BEFORE psk_hash: 126770ba77304106160859262e4d0a2ffed13ed794fc703023111345fc746dd0
WRITE returned: False
AFTER firmware:  GFUSB_GM168SEC_APP_10034
AFTER psk_hash:  126770ba77304106160859262e4d0a2ffed13ed794fc703023111345fc746dd0
PSK_NOW_ZERO: False
FIRMWARE_UNCHANGED: True
```

`preset_psk_write()`'s return value is the device's own protocol-level status byte
(`message[0] == 0x00` in `goodix.py`) — the sensor explicitly rejected the write at the
protocol level; this was not a Python exception, a timeout, or a dropped connection. The
built-in post-write read (part of the approved script, not an improvised retry) confirms no
corruption: `AFTER` is byte-identical to `BEFORE` on both firmware and PSK hash — the stored
PMK is unchanged, still `126770ba77304106160859262e4d0a2ffed13ed794fc703023111345fc746dd0`,
not the zero hash and not some third, torn value. The device also remained fully responsive
to USB commands after the rejected write (it answered `firmware_version()` and
`preset_psk_read()` normally), so it did not disappear from the bus.

**Stopped here per the brief.** "The write returns an error" is one of the brief's explicit
stop conditions ("If ANYTHING is unexpected ... STOP IMMEDIATELY AND REPORT ... Do not
improvise. Do not 'try the other flag value'... Any retry-with-variations if the write fails"
is explicitly forbidden). No retry, no variation of flags/offset/payload, and no run of the
Task 3 enroll binary was attempted — Step 3's driver re-check is contingent on `PSK_NOW_ZERO:
True`, which this run did not reach. The sensor is left exactly as it was before this task:
firmware `GFUSB_GM168SEC_APP_10034`, stored PMK hash
`126770ba77304106160859262e4d0a2ffed13ed794fc703023111345fc746dd0` (unchanged, non-zero).

**Open question for whoever picks this up next:** the call matches upstream `write_psk()`
verbatim and the firmware gate was the only thing Task 3 changed, but the device still NAK'd
the write. Two live hypotheses, neither investigated further here per the stop-immediately
instruction: (1) `PSK_WHITE_BOX`'s payload may itself be tied to a specific firmware/PSK-state
precondition beyond the simple version-string gate Task 3 patched, so 10034 may reject it for
a reason upstream's 10019-only flow never had to handle; (2) some other device-side
precondition (mode/lock state) not captured by `nop()` + `firmware_version()` +
`preset_psk_read()` may be required before `preset_psk_write` is accepted. Resolving this
needs protocol-level investigation (e.g. comparing this device's raw command trace against a
working 10019 capture), not a blind retry on this same hardware.
