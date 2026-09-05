# Goodix 521d Fingerprint on blackbird — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fingerprint unlock on blackbird via fprintd/libfprint for Goodix `27c6:521d`, targeting sensor firmware `GFUSB_GM168SEC_APP_10034` (the build Windows uses) so dual-booting Windows does not break it.

**Architecture:** Gated phases, cheapest first. Tasks 1–3 learn the sensor's real state using only read operations and a locally-built driver. Task 4A then searches the Windows install offline for the sensor's PSK — read-only, no VM, no reboot — and may end the investigation outright. Tasks 4–6 run only if Task 4A comes back empty, escalating to USB capture from a Windows VM and then Ghidra. Tasks 7–8 package the result for NixOS and prove the dual-boot round trip.

**Status note (2026-09-05):** Tasks 1–3 are complete. The firmware question is settled — the sensor runs `GFUSB_GM168SEC_APP_10034` and the widened gate accepts it, so **nothing needs flashing**. The single remaining blocker is the sensor's PSK, `126770ba…746dd0`, confirmed identical by two independent code paths.

**Tech Stack:** Nix flakes + flake-parts + haumea, meson/ninja, libfprint (`infinytum/libfprint` fork), fprintd, Python 3 + pyusb, libvirt/QEMU/swtpm, usbmon.

**Spec:** `docs/superpowers/specs/2026-09-05-goodix-521d-fingerprint-design.md`

## Global Constraints

- **Conventional commits required:** `<type>(<scope>): <subject>`. Types: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `ci`. Scope here is `blackbird` or `packages`. Never mention Claude in commit messages or author.
- **Commit straight to `master`.** This repo does not use feature branches or worktrees; branch-only config gets reverted by the routine deploy.
- **Run `just fmt` (alejandra) before committing any `.nix` change.** CI `format.yml` fails on unformatted Nix.
- **Never write to the sensor without explicit user approval.** No `erase_firmware()`, `update_firmware()`, or `write_psk()` calls, and no attaching the sensor to a booting Windows VM, without asking first.
- **All work runs from raider**, which is the deploy driver (`NIKS3_AUTH_TOKEN_FILE` is set only there). Deploy with `just deploy blackbird`.
- **blackbird is at `blackbird.bat-boa.ts.net`** and it suspends. If SSH times out, retry — the host is not down.
- **Rebooting blackbird is cheap.** This work is driven from raider, so blackbird can be rebooted — including into Windows — without disrupting the session. Task 5 has a real-dual-boot fallback that relies on this, and Task 8 requires a Windows boot outright.
- **Investigation artifacts live in the scratchpad, not the repo.** Only durable outputs (packages, host config, recorded findings) get committed.
- **blackbird is not in tier1**, so none of this touches the weekly-deploy path.

**Scratchpad root** (referred to below as `$SCRATCH`):
`/tmp/claude-1000/-home-arosenfeld-Code-nixos/5ed6a048-a561-459a-abc4-0f0756db5fc5/scratchpad`

## File Structure

| Path | Responsibility |
|---|---|
| `$SCRATCH/gfd/` | `goodix-fp-dump` clone (probe protocol library). Not committed. |
| `$SCRATCH/gfd/probe_521d.py` | Read-only sensor probe. Not committed. |
| `$SCRATCH/win-driver/` | Extracted Windows driver binaries. Not committed. |
| `$SCRATCH/captures/` | usbmon traces. Not committed. |
| `packages/libfprint-goodix-521d/default.nix` | Patched libfprint fork. Auto-loaded by haumea into the global overlay as `pkgs.libfprint-goodix-521d`. |
| `hosts/blackbird/configuration.nix` | Enables `services.fprintd` with an fprintd overridden onto the fork. |
| `docs/superpowers/specs/2026-09-05-goodix-521d-fingerprint-design.md` | Spec; gains a "Findings" section as tasks complete. |

Defining a **new** package name keeps this additive. Do **not** overlay `libfprint` itself — the overlay in `flake-modules/lib.nix` applies to every host, and replacing `libfprint` globally would drag all nine hosts onto a five-year-old fork.

---

### Task 1: Read-only sensor probe

Establishes the two facts everything else branches on: what firmware the sensor runs, and whether its PSK is already the all-zero key.

**Files:**
- Create: `$SCRATCH/gfd/probe_521d.py`
- Modify: `docs/superpowers/specs/2026-09-05-goodix-521d-fingerprint-design.md` (append Findings)

**Interfaces:**
- Consumes: nothing.
- Produces: two facts consumed by Task 3's branch — `FIRMWARE` (a string like `GFUSB_GM168SEC_APP_10034`) and `PSK_IS_ZERO` (bool).

- [ ] **Step 1: Clone the protocol library with its firmware submodule**

```bash
cd "$SCRATCH"
git clone --recurse-submodules https://github.com/goodix-fp-linux-dev/goodix-fp-dump.git gfd
```

The `firmware` submodule is a separate public repo (`goodix-fp-linux-dev/goodix-firmware`) holding `52xd/GFUSB_GM168SEC_APP_10019.bin`. Without `--recurse-submodules` the directory is empty.

- [ ] **Step 2: Write the read-only probe**

Create `$SCRATCH/gfd/probe_521d.py`. This calls **only** read operations. It must never call `erase_firmware()`, `update_firmware()`, or `write_psk()`.

```python
#!/usr/bin/env python3
"""Read-only probe of the Goodix 521d sensor.

Calls only nop(), firmware_version() and preset_psk_read().
Never erases, flashes, or writes a PSK.
"""
import hashlib
import sys

import goodix
import protocol

PRODUCT = 0x521D
PSK_FLAGS = 0xBB020001
ZERO_PMK_HASH = hashlib.sha256(bytes(32)).digest()


def main() -> int:
    device = goodix.Device(PRODUCT, protocol.USBProtocol)
    device.nop()

    firmware = device.firmware_version()
    print(f"FIRMWARE: {firmware}")

    reply = device.preset_psk_read(PSK_FLAGS, len(ZERO_PMK_HASH), 0)
    if not reply[0]:
        print("PSK: read failed")
        return 1

    flags, psk = reply[1], reply[2]
    print(f"PSK_FLAGS: 0x{flags:08x}")
    print(f"PSK_HASH: {psk.hex()}")
    print(f"PSK_IS_ZERO: {psk == ZERO_PMK_HASH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 3: Copy the probe to blackbird and run it**

The sensor is on blackbird, not raider. All six Python dependencies are in nixpkgs.

```bash
scp "$SCRATCH/gfd/probe_521d.py" blackbird.bat-boa.ts.net:/tmp/
ssh blackbird.bat-boa.ts.net 'cd /tmp && git clone --recurse-submodules \
  https://github.com/goodix-fp-linux-dev/goodix-fp-dump.git gfd && \
  cp /tmp/probe_521d.py gfd/'

ssh -t blackbird.bat-boa.ts.net 'cd /tmp/gfd && sudo nix shell --impure --expr \
  "(import <nixpkgs> {}).python3.withPackages (ps: with ps; \
     [pyusb crcmod crccheck pycryptodome python-periphery spidev])" \
  -c python3 probe_521d.py'
```

`sudo` is required — the sensor has no udev rule granting user access. `protocol.py` imports `periphery` and `spidev` at module scope even for the USB path, which is why they are in the environment.

**Do not** use the flat form `nix shell nixpkgs#python3 nixpkgs#python3Packages.pyusb …`. It puts each package's `bin/` on `PATH` but does not compose their `PYTHONPATH`s, so every import fails with `ModuleNotFoundError`. `python3.withPackages` is the mechanism that actually builds a composed interpreter environment.

- [ ] **Step 4: Verify the expected output shape**

Expected: four lines, `FIRMWARE:`, `PSK_FLAGS:`, `PSK_HASH:`, `PSK_IS_ZERO:`.

Most likely `FIRMWARE: GFUSB_GM168SEC_APP_10034` and `PSK_IS_ZERO: False`, since Windows was last booted on this machine in May 2026.

If it instead prints a `MILAN_GM168SEC_IAP_*` firmware, the sensor is sitting in its bootloader and is unusable until flashed — **stop and report**, because recovering it requires a write and therefore explicit approval.

If it raises `TimeoutError("Device not found")`, confirm the sensor is present with `lsusb -d 27c6:521d`.

- [ ] **Step 5: Record findings in the spec and commit**

Append a `## Findings` section to the spec with the four values verbatim and the date.

```bash
cd /home/arosenfeld/Code/nixos
git add docs/superpowers/specs/2026-09-05-goodix-521d-fingerprint-design.md
git commit -m "docs(blackbird): record Goodix 521d sensor probe findings"
```

---

### Task 2: Nix package for the patched libfprint fork

**Files:**
- Create: `packages/libfprint-goodix-521d/default.nix`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `pkgs.libfprint-goodix-521d`, a libfprint 1.94.1 build carrying only the `goodixtls52xd` driver, with a widened firmware gate. Its `$out/lib/pkgconfig/libfprint-2.pc` is what Task 7 feeds to `fprintd.override`. Its build tree also yields `examples/enroll` and `examples/img-capture`, used by Task 3.

- [ ] **Step 1: Write the derivation**

Packages in this repo are directories containing `default.nix` taking `{pkgs, ...}`, auto-loaded by haumea via `loadPackages` in `flake-modules/lib.nix`.

Create `packages/libfprint-goodix-521d/default.nix`:

```nix
{pkgs, ...}: let
  inherit (pkgs) lib stdenv fetchFromGitHub;
in
  stdenv.mkDerivation {
    pname = "libfprint-goodix-521d";
    version = "1.94.1-unstable-2021-11-17";

    src = fetchFromGitHub {
      owner = "infinytum";
      repo = "libfprint";
      rev = "5e14af7f136265383ca27756455f00954eef5db1";
      hash = lib.fakeHash;
    };

    nativeBuildInputs = with pkgs; [
      meson
      ninja
      pkg-config
    ];

    buildInputs = with pkgs; [
      glib
      libgudev
      gusb # nixpkgs attribute is `gusb`, not `libgusb` (which does not exist)
      nss
      openssl
      pixman
      systemdLibs
    ];

    # The fork is from 2021 and does not compile clean against modern GCC.
    # The AUR package libfprint-goodix-521d applies the same relaxation.
    env.NIX_CFLAGS_COMPILE = "-Wno-incompatible-pointer-types";

    # Widen the firmware gate. Upstream hard-compares against 10019; Windows
    # ships 10034. A prefix match keeps future firmware revisions working
    # without another patch.
    postPatch = ''
      substituteInPlace libfprint/drivers/goodixtls/goodix52xd.c \
        --replace-fail \
          'if (strcmp(firmware, GOODIX_52XD_FIRMWARE_VERSION)) {' \
          'if (strncmp(firmware, "GFUSB_GM168SEC_APP_", 19)) {'
    '';

    mesonFlags = [
      # Build only our driver. The fork carries 2021-era drivers that are not
      # worth compiling against a modern toolchain.
      "-Ddrivers=goodixtls52xd"
      "-Dintrospection=false"
      "-Ddoc=false"
      "-Dgtk-examples=false"
      "-Dudev_rules_dir=${placeholder "out"}/lib/udev/rules.d"
      "-Dudev_hwdb_dir=${placeholder "out"}/lib/udev/hwdb.d"
    ];

    meta = with lib; {
      description = "libfprint fork with the goodixtls driver for Goodix 27c6:521d";
      homepage = "https://github.com/infinytum/libfprint";
      license = licenses.lgpl21Plus;
      platforms = platforms.linux;
    };
  }
```

Note the `goodixtls` helper requires **openssl** and **threads** (see `meson.build:220-230`), which is why openssl is in `buildInputs` and is not optional.

- [ ] **Step 2: Build to obtain the real source hash**

```bash
cd /home/arosenfeld/Code/nixos
nix build .#libfprint-goodix-521d 2>&1 | tail -20
```

Expected: FAIL with a hash mismatch reporting `specified: sha256-AAAA…` and `got: sha256-<real>`. Replace `lib.fakeHash` with the reported value.

- [ ] **Step 3: Build for real**

```bash
nix build .#libfprint-goodix-521d 2>&1 | tail -30
```

Expected: PASS.

If meson fails resolving `-Ddrivers=goodixtls52xd`, confirm the driver key against `libfprint/meson.build:144` — it is `goodixtls52xd`, not `goodix52xd`.

If `--replace-fail` errors, the `strcmp` line has drifted; read `libfprint/drivers/goodixtls/goodix52xd.c` around line 106 and match the actual text.

- [ ] **Step 4: Verify the driver is actually in the build**

```bash
nix build .#libfprint-goodix-521d --no-link --print-out-paths
strings "$(nix build .#libfprint-goodix-521d --no-link --print-out-paths)"/lib/libfprint-2.so* \
  | grep -c "GFUSB_GM168SEC_APP_" 
```

Expected: at least 1 — the firmware version literal is still compiled in even though the comparison is now a prefix match.

- [ ] **Step 5: Format and commit**

```bash
cd /home/arosenfeld/Code/nixos
just fmt
git add packages/libfprint-goodix-521d/default.nix
git commit -m "feat(packages): add libfprint fork with Goodix 521d driver"
```

---

### Task 3: Run the patched driver against the sensor

The decision point for the whole plan. libfprint's CLI examples build unconditionally (`meson.build:318`) and need only glib — no GTK, no DBus, no fprintd daemon.

**Files:**
- Modify: `docs/superpowers/specs/2026-09-05-goodix-521d-fingerprint-design.md` (append to Findings)

**Interfaces:**
- Consumes: `pkgs.libfprint-goodix-521d` from Task 2; `FIRMWARE` / `PSK_IS_ZERO` from Task 1.
- Produces: a verdict — `ENROLL_OK` (go to Task 7) or a precise failure point plus the sensor's real PMK hash (go to Task 4).

- [ ] **Step 1: Build the examples on blackbird**

The examples are not installed by `meson install`, so run them from a build tree. Build on blackbird so the binary and the sensor are on the same host.

```bash
ssh blackbird.bat-boa.ts.net 'cd /tmp && git clone -b unstable \
  https://github.com/infinytum/libfprint.git lfp-fork && cd lfp-fork && \
  sed -i "s/if (strcmp(firmware, GOODIX_52XD_FIRMWARE_VERSION)) {/if (strncmp(firmware, \"GFUSB_GM168SEC_APP_\", 19)) {/" \
    libfprint/drivers/goodixtls/goodix52xd.c'

ssh blackbird.bat-boa.ts.net 'cd /tmp/lfp-fork && nix shell \
  nixpkgs#meson nixpkgs#ninja nixpkgs#pkg-config nixpkgs#gcc \
  nixpkgs#glib nixpkgs#gusb nixpkgs#openssl nixpkgs#nss \
  nixpkgs#pixman nixpkgs#libgudev nixpkgs#systemdLibs \
  -c bash -c "CFLAGS=-Wno-incompatible-pointer-types meson setup build \
     -Ddrivers=goodixtls52xd -Dintrospection=false -Ddoc=false && ninja -C build"'
```

Expected: build succeeds, producing `build/examples/enroll`.

- [ ] **Step 2: Confirm the patch took**

```bash
ssh blackbird.bat-boa.ts.net 'grep -n "strncmp(firmware" /tmp/lfp-fork/libfprint/drivers/goodixtls/goodix52xd.c'
```

Expected: one hit around line 106. If zero hits, the `sed` did not match — fix before running against hardware.

- [ ] **Step 3: Run enroll with full driver debug**

```bash
ssh -t blackbird.bat-boa.ts.net 'cd /tmp/lfp-fork && sudo \
  G_MESSAGES_DEBUG=all LIBUSB_DEBUG=3 ./build/examples/enroll 2>&1 | tee /tmp/enroll.log'
```

This is non-destructive and that is a verified property, not an assumption: the `goodixtls` driver contains no firmware erase or write path, and its `goodix_send_preset_psk_write()` has **no callers** — it is dead code. `goodix52xd.c` only ever calls `goodix_send_preset_psk_read()` and `memcmp`s the result.

- [ ] **Step 4: Read the outcome**

Retrieve the log and classify:

```bash
scp blackbird.bat-boa.ts.net:/tmp/enroll.log "$SCRATCH/captures/enroll-baseline.log"
grep -E "Device firmware|Device PSK|Invalid device" "$SCRATCH/captures/enroll-baseline.log"
```

Three possible outcomes:

1. **Enroll succeeds** — the protocol matches on 10034 and the PSK was already zero. Skip Tasks 4–6, go to Task 7.
2. **`Invalid device PSK: 0x…`** — the expected case. The firmware gate now passes and the driver reached `ACTIVATE_CHECK_PSK`. **The logged hex is the sensor's real stored PMK hash** — the single most valuable datum for Task 5. Record it.
3. **Anything else** (`Invalid device firmware`, USB timeouts, activation errors) — record the exact failure point; it narrows what Task 5 must capture.

- [ ] **Step 5: Record findings and commit**

Append outcome, the real PMK hash if obtained, and the failure point to the spec's Findings section.

```bash
cd /home/arosenfeld/Code/nixos
git add docs/superpowers/specs/2026-09-05-goodix-521d-fingerprint-design.md
git commit -m "docs(blackbird): record patched-driver enroll attempt on 10034"
```

- [ ] **Step 6: Branch**

If outcome 1 → go to **Task 7**. Otherwise → go to **Task 4**.

---

### Task 4A: Offline search of the Windows install for the sensor's PSK

**Inserted after Task 3 established that the ONLY remaining blocker is the PSK.** Runs before Tasks 4-6 and may make all three unnecessary.

Entirely read-only: no VM, no Windows boot, no sensor write, no reboot. The Windows partition is mounted read-only and the interesting files are copied off; all analysis happens on the copies.

**Rationale.** The Windows driver must know the PSK to complete its handshake. Controller analysis already ruled out the easy possibilities — the PSK is not the zero key, matches none of the 29 published Goodix constants, and neither its hash nor the key itself appears anywhere in `wbdi.dll`, `GoodixEngineAdapter.dll`, or `SessionService.exe` (verified with a sliding 32-byte window over all three). That leaves it stored Windows-side or derived at runtime. This task tests the first, cheaper hypothesis.

**Files:**
- Create: `$SCRATCH/psk-hunt/` (copies + scripts; not committed)
- Modify: `docs/superpowers/specs/2026-09-05-goodix-521d-fingerprint-design.md` (Findings)

**Interfaces:**
- Consumes: the target PMK hash `126770ba77304106160859262e4d0a2ffed13ed794fc703023111345fc746dd0`, confirmed identical by two independent code paths (Task 1's probe and Task 3's driver log).
- Produces: either **the PSK preimage** — in which case Tasks 4, 5 and 6 are all skipped and we go straight to patching the driver's expected key — or a definitive negative that justifies the more expensive routes.

- [ ] **Step 1: Mount the Windows partition read-only and copy out the candidates**

Windows lives on `/dev/nvme0n1p5`. Mount read-only; never rw.

```bash
ssh blackbird.bat-boa.ts.net 'sudo mkdir -p /mnt/win && sudo mount -o ro,noatime /dev/nvme0n1p5 /mnt/win && echo MOUNTED'
```

Copy out only these, then unmount immediately. Do **not** scan or enumerate the whole 425 GB partition — target these paths directly:

- `/Windows/System32/config/SYSTEM` — the hive holding `HKLM\System\CurrentControlSet\Control\Goodix\FP`, which `WbdiUsb.inf` creates
- `/Windows/System32/config/SOFTWARE`
- `/Windows/System32/WinBioDatabase/` — WinBio template store
- any `Goodix` directory under `/ProgramData` or `/Windows/System32` (check existence first; skip silently if absent)

- [ ] **Step 2: Sliding-window preimage search**

The decisive test. For each copied file, hash every 32-byte window and compare against the target. A PSK stored verbatim anywhere in these files is found by this.

```python
import hashlib, sys
TARGET = bytes.fromhex("126770ba77304106160859262e4d0a2ffed13ed794fc703023111345fc746dd0")
for path in sys.argv[1:]:
    data = open(path, "rb").read()
    hit = next((i for i in range(len(data) - 31)
                if hashlib.sha256(data[i:i+32]).digest() == TARGET), None)
    print(f"{path}: {'FOUND at ' + hex(hit) if hit is not None else 'not found'}")
```

Hives are tens of MB, so this is minutes of CPU, not hours. If it reports FOUND, extract those 32 bytes — that is the sensor's PSK, and it is the whole answer.

- [ ] **Step 3: Targeted registry inspection**

Independently of the byte search, dump and read the Goodix keys. All four tools are in nixpkgs: `hivex`, `chntpw`, `python3Packages.python-registry`, `regripper`.

Inspect `HKLM\System\CurrentControlSet\Control\Goodix\FP` (and the same path under every `ControlSet00N`). `WbdiUsb.inf` is known to create `SupportCMDOKBSSO`, `SupportPBSSO`, `SupportECSSO`, `EnableRemoteWakeup`, `MSOnePressTimeOut`, `S3OnePressTimeOut`, `S0IdleTimeout`, `SubmitNeedDelay`. Report any value beyond that set, especially binary blobs of 32 or 96 bytes — 96 would be a white-box-wrapped key like goodix-fp-dump's `PSK_WHITE_BOX`.

Also check the driver's device instance keys under `HKLM\System\CurrentControlSet\Enum\USB\VID_27C6&PID_521D\`.

- [ ] **Step 4: Record the outcome and commit**

Append to the spec's existing `## Findings (2026-09-05)` section: what was searched, and either the recovered key or an explicit statement that the offline search was negative and which files it covered. A precise negative is a valuable result — it is what justifies spending a VM or Ghidra on the next attempt.

```bash
git add docs/superpowers/specs/2026-09-05-goodix-521d-fingerprint-design.md
git commit -m "docs(blackbird): record offline Windows PSK search result"
```

---

### Task 4B: Provision the zero PSK — THE FIRST SENSOR WRITE

**User approval recorded 2026-09-05.** Task 4A established that the PSK is vendor-sealed and unrecoverable by static search, so the user chose the fallback their success bar already sanctioned: overwrite the sensor's PSK with the all-zero key the community driver expects.

**This is the only task in the plan that writes to the sensor.** It writes a PSK and nothing else. It must never touch firmware.

**Why this is now cheap.** In the upstream community flow, PSK provisioning and a firmware downgrade are bundled inside `driver_52xd.py`'s `main()`, which erases any firmware that is not exactly 10019. Task 3 removed the need for that half: the sensor already runs 10034 and our patched driver accepts it. So this task performs the PSK write *alone* — no erase, no flash, no bootloader risk.

**Files:**
- Create: `$SCRATCH/gfd/write_zero_psk.py` (not committed)
- Modify: spec Findings

**Interfaces:**
- Consumes: the patched driver from Task 2; the confirmed firmware `GFUSB_GM168SEC_APP_10034`.
- Produces: a sensor whose stored PMK hash is `SHA256(32 zero bytes)` = `66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925`, enabling driver activation to pass `ACTIVATE_CHECK_PSK`.

- [ ] **Step 1: Write the surgical script**

It must call **only** `preset_psk_write`, guarded by firmware assertions on both sides. Reuse `PSK_WHITE_BOX` verbatim from `driver_52xd.py`; do not retype it.

```python
#!/usr/bin/env python3
"""Provision the all-zero PSK on a Goodix 521d. Writes a PSK and NOTHING else.

Never calls erase_firmware(), update_firmware(), or driver_52xd.main().
"""
import hashlib, sys
import goodix, protocol
from driver_52xd import PSK_WHITE_BOX          # reuse, do not retype

PRODUCT, PSK_FLAGS = 0x521D, 0xBB020001
EXPECT_FW = "GFUSB_GM168SEC_APP_10034"
ZERO_PMK = hashlib.sha256(bytes(32)).digest()

def read_state(dev):
    fw = dev.firmware_version()
    reply = dev.preset_psk_read(PSK_FLAGS, 32, 0)
    if not reply[0]:
        raise SystemExit("PSK read failed")
    return fw, reply[2]

def main() -> int:
    dev = goodix.Device(PRODUCT, protocol.USBProtocol)
    dev.nop()

    fw, before = read_state(dev)
    print(f"BEFORE firmware: {fw}\nBEFORE psk_hash: {before.hex()}")
    if fw != EXPECT_FW:                      # refuse to touch an unexpected sensor
        raise SystemExit(f"ABORT: expected {EXPECT_FW}, found {fw}")
    if before == ZERO_PMK:
        print("Already zero-keyed; nothing to do."); return 0

    ok = dev.preset_psk_write(0xbb010003, PSK_WHITE_BOX, 114, 0,
                              bytes.fromhex("56a5bb956b7c8d9e0000"))
    print(f"WRITE returned: {ok}")

    fw2, after = read_state(dev)
    print(f"AFTER firmware: {fw2}\nAFTER psk_hash: {after.hex()}")
    print(f"PSK_NOW_ZERO: {after == ZERO_PMK}")
    print(f"FIRMWARE_UNCHANGED: {fw2 == fw}")
    return 0 if after == ZERO_PMK and fw2 == fw else 1

if __name__ == "__main__":
    sys.exit(main())
```

The firmware assertion on both sides is the safety net: if the firmware string changes across this operation, something wrote flash and that must be reported immediately.

- [ ] **Step 2: Run it**

Same environment as the probe — note `python3.withPackages`, and `NIX_PATH` for sudo:

```bash
ssh -t blackbird.bat-boa.ts.net 'cd /tmp/gfd && sudo NIX_PATH=nixpkgs=flake:nixpkgs \
  nix shell --impure --expr \
  "(import <nixpkgs> {}).python3.withPackages (ps: with ps; \
     [pyusb crcmod crccheck pycryptodome python-periphery spidev])" \
  -c python3 write_zero_psk.py'
```

Required: `PSK_NOW_ZERO: True` and `FIRMWARE_UNCHANGED: True`.

- [ ] **Step 3: Confirm the driver now activates**

Re-run the Task 3 enroll binary. Success is the driver getting **past** state 4 (`ACTIVATE_CHECK_PSK`) and reaching the finger-scan stage — no finger required to prove it, and none is available remotely.

```bash
ssh blackbird.bat-boa.ts.net 'cd /tmp/lfp-fork && sudo timeout 30 \
  bash -c "G_MESSAGES_DEBUG=all ./build/examples/enroll > /tmp/enroll-postpsk.log 2>&1"; \
  grep -E "Device PSK|Invalid device|scan|state" /tmp/enroll-postpsk.log | head -20'
```

Expected: no `Invalid device PSK`, and activation proceeding to await a finger.

- [ ] **Step 4: Record and commit**

Append before/after PSK hashes, the firmware-unchanged confirmation, and the activation outcome to the spec's Findings.

**If the write fails or half-completes:** report immediately and stop. Do not retry blind and do not reach for the firmware path. The sensor's PSK may be left in a state Windows must re-provision; Windows Hello may need re-enrolment. That is recoverable — a wedged firmware would not be, which is exactly why this task never touches it.

---

### Task 4: usbmon baseline of the Linux attempt

**Superseded for now by Task 4B.** Run only if Task 4B fails and the user asks to escalate to protocol capture.

Captures our own failing exchange so the Windows trace in Task 5 is diffable against a known-meaning reference.

**Files:**
- Create: `$SCRATCH/captures/linux-enroll.mon`

**Interfaces:**
- Consumes: the working `build/examples/enroll` from Task 3.
- Produces: `linux-enroll.mon`, a usbmon text trace of the Linux driver's exchange up to its failure point.

- [ ] **Step 1: Enable usbmon**

```bash
ssh blackbird.bat-boa.ts.net 'sudo modprobe usbmon && \
  sudo mount -t debugfs none /sys/kernel/debug 2>/dev/null; \
  sudo ls /sys/kernel/debug/usb/usbmon/'
```

Expected: a listing including `5u`. Bus 5 is the sensor's bus — confirm with `lsusb -d 27c6:521d`, which reports `Bus 005`.

- [ ] **Step 2: Capture while re-running enroll**

```bash
ssh blackbird.bat-boa.ts.net 'sudo timeout 60 cat /sys/kernel/debug/usb/usbmon/5u > /tmp/linux-enroll.mon &
  sleep 2; cd /tmp/lfp-fork && sudo G_MESSAGES_DEBUG=all ./build/examples/enroll; sleep 2'
scp blackbird.bat-boa.ts.net:/tmp/linux-enroll.mon "$SCRATCH/captures/"
```

- [ ] **Step 3: Verify the trace is non-empty and contains the exchange**

```bash
wc -l "$SCRATCH/captures/linux-enroll.mon"
```

Expected: more than 20 lines. If zero, the capture started after the program finished — increase the leading `sleep`.

- [ ] **Step 4: Commit nothing**

This trace stays in the scratchpad; it is raw investigation data, not a repo artifact. Record only its summary in the spec later.

---

### Task 5: Windows VM capture

**Run only if Task 3 did not enroll successfully AND Task 4A did not recover the PSK.**

**STOP — this task requires explicit user approval before Step 4.** Attaching the sensor to a booting Windows guest may cause the Windows driver to flash it. Writing 10034 serves the goal, but it is still a write.

**Files:**
- Create: `$SCRATCH/captures/win-{init,enroll,verify}.mon`

**Interfaces:**
- Consumes: `$SCRATCH/win-driver/` (already extracted: `WbdiUsb.inf`, `wbdi.dll`, `GoodixEngineAdapter.dll`, `SessionService.exe`).
- Produces: three usbmon traces of the Windows driver, to be diffed against `linux-enroll.mon`.

- [ ] **Step 1: Fetch a Windows 11 evaluation ISO**

Use a Windows 11 Enterprise evaluation ISO. Do **not** boot the existing `nvme0n1p5` install: raw-disk passthrough of a live Windows risks BitLocker lockout, activation churn against different virtual hardware, and filesystem corruption if the partition was hibernated.

- [ ] **Step 2: Create the VM**

blackbird already has libvirtd, qemu_kvm and swtpm via `constellation.virtualization`. Windows 11 requires UEFI + TPM 2.0, which swtpm provides.

```bash
ssh blackbird.bat-boa.ts.net 'sudo systemctl start libvirtd && sudo virt-install \
  --name win11-fpcapture \
  --osinfo win11 \
  --memory 8192 --vcpus 4 \
  --disk path=/var/tmp/win11-fpcapture.qcow2,size=64,format=qcow2 \
  --cdrom /var/tmp/Win11_Eval.iso \
  --machine q35 --boot uefi \
  --tpm backend.type=emulator,backend.version=2.0,model=tpm-crb \
  --graphics spice --noautoconsole'
```

- [ ] **Step 3: Install Windows, then shut the guest down**

Complete OOBE. No network account needed. Shut down before attaching the sensor.

- [ ] **Step 4: ASK THE USER before attaching the sensor**

Confirm approval, then attach by vendor/product. Nothing is bound to the device on the host, so no unbind is required.

```bash
ssh blackbird.bat-boa.ts.net 'cat > /tmp/fp-hostdev.xml <<XML
<hostdev mode="subsystem" type="usb" managed="yes">
  <source><vendor id="0x27c6"/><product id="0x521d"/></source>
</hostdev>
XML
sudo virsh attach-device win11-fpcapture /tmp/fp-hostdev.xml --live'
```

- [ ] **Step 5: Start the host-side capture, then boot the guest**

Capture on the **host**. QEMU's `usb-host` submits URBs through host usbfs and usbmon taps at the usbcore layer beneath it, so the host sees every transfer the guest makes — with zero capture software installed in the guest.

```bash
ssh blackbird.bat-boa.ts.net 'sudo sh -c "cat /sys/kernel/debug/usb/usbmon/5u > /tmp/win-init.mon" &
  sudo virsh start win11-fpcapture'
```

- [ ] **Step 6: Sideload the driver in the guest**

Copy `$SCRATCH/win-driver/` into the guest, then:

```
pnputil /add-driver WbdiUsb.inf /install
```

If it is rejected for signing, enable test signing (`bcdedit /set testsigning on`) and reboot the guest. The package is being installed outside its original catalog chain, so this is expected.

- [ ] **Step 7: Capture enroll and verify separately**

Stop `win-init.mon`. Start `win-enroll.mon`, enrol a finger through Windows Hello, stop it. Start `win-verify.mon`, perform a verify, stop it. Separate files keep the three protocol phases distinguishable.

- [ ] **Step 8: Retrieve traces and confirm they contain traffic**

```bash
scp blackbird.bat-boa.ts.net:/tmp/win-*.mon "$SCRATCH/captures/"
wc -l "$SCRATCH/captures/"win-*.mon
```

Expected: each well over 100 lines. `win-init.mon` is the one that reveals whether Windows flashed the sensor — look for large sequential bulk writes.

- [ ] **Step 9: Detach the sensor and stop the VM**

```bash
ssh blackbird.bat-boa.ts.net 'sudo virsh detach-device win11-fpcapture /tmp/fp-hostdev.xml --live; \
  sudo virsh shutdown win11-fpcapture'
```

- [ ] **Step 10: Re-run the Task 1 probe**

Determine whether the sensor's firmware or PSK changed during the Windows session. This is the direct experimental answer to spec Risk 2 — whether Windows re-provisions the PSK on every boot.

Record both values in the spec and commit.

#### Fallback: capture from a real Windows boot

Dual-booting blackbird is cheap — this work is driven from raider, so blackbird is free to reboot without disrupting the session. If the VM route stalls (driver signing, passthrough trouble, Hello refusing to enrol in a guest), abandon it and capture from a real Windows boot instead.

The trade is that host-side `usbmon` is unavailable, because in this scenario Windows *is* the host. The capture has to happen inside Windows:

1. Boot blackbird into its existing Windows install. No driver sideloading is needed — the real Goodix driver is already installed there, which also removes the test-signing problem entirely.
2. Install [USBPcap](https://desowin.org/usbpcap/) and identify the sensor's root hub.
3. Capture three separate files across the same three scenarios — boot/init, Hello enrol, Hello verify — with `USBPcapCMD.exe`.
4. Reboot into NixOS, copy the `.pcap` files to `$SCRATCH/captures/`, and re-run the Task 1 probe to see what the Windows session changed.

The resulting `.pcap` files open in Wireshark with native USBPcap dissection, and carry the same URBs the usbmon route would have produced — so Task 6's analysis is unchanged either way. This path is in some ways *simpler* than the VM (no VM build, no sideload, no signing), at the cost of needing someone at the machine and losing the ability to iterate quickly.

**Prefer the VM route first** because it can be driven entirely over SSH; treat this as the escape hatch rather than the default.

---

### Task 6: Protocol delta and driver patch

**Run only if Task 5 ran.**

**Files:**
- Modify: `packages/libfprint-goodix-521d/default.nix` (extend `postPatch`)
- Modify: the spec (Findings)

**Interfaces:**
- Consumes: `linux-enroll.mon` (Task 4), `win-*.mon` (Task 5), the real PMK hash (Task 3).
- Produces: an updated `pkgs.libfprint-goodix-521d` that activates against the sensor's actual state.

- [ ] **Step 1: Decode both traces with the known framing**

The packet framing is already documented in the fork's `libfprint/drivers/goodixtls/goodix_proto.c` and the Python `protocol.py`. Decode the Windows PSK exchange and compare it against what `goodix52xd.c` does at `ACTIVATE_CHECK_PSK`.

- [ ] **Step 2: Where the trace is ambiguous, use re-shell on `wbdi.dll`**

`schlarpc/re-shell` is a Nix-flake reverse-engineering environment (Ghidra, radare2, Frida, mitmproxy). It is the right tool specifically for PSK derivation, which a wire trace may not fully explain.

```bash
cd "$SCRATCH" && git clone https://github.com/schlarpc/re-shell.git
cp win-driver/wbdi.dll re-shell/
cd re-shell && nix develop
```

Anchors already known: the string `GFUSB_GM168SEC_APP_10034`, and the PSK flag constant `0xbb020001` which occurs 3 times as little-endian `01 00 02 bb` at offsets `0x3c2c4`, `0x73c49`, `0x73f65`.

- [ ] **Step 3: Encode the finding as a `postPatch` change**

Extend `postPatch` in the derivation with whatever the delta requires — most likely replacing the `goodix_52xd_psk_0` expected hash with the sensor's real one, or adjusting the activation sequence.

- [ ] **Step 4: Rebuild and re-run enroll**

```bash
nix build .#libfprint-goodix-521d 2>&1 | tail -20
```

Then repeat Task 3 Steps 1–4. Expected: enroll succeeds.

- [ ] **Step 5: Format, commit**

```bash
just fmt
git add packages/libfprint-goodix-521d/default.nix docs/superpowers/specs/2026-09-05-goodix-521d-fingerprint-design.md
git commit -m "fix(packages): align Goodix 521d driver with firmware 10034 protocol"
```

---

### Task 7: NixOS packaging on blackbird

**Files:**
- Modify: `hosts/blackbird/configuration.nix`

**Interfaces:**
- Consumes: `pkgs.libfprint-goodix-521d`.
- Produces: a working `services.fprintd` on blackbird, and `fprintd-enroll` / `fprintd-verify` on PATH.

- [ ] **Step 1: Enable fprintd against the fork**

`fprintd` accepts `libfprint` as an overridable argument (verified: it appears in `fprintd.override.__functionArgs`). Overriding it here keeps the fork scoped to this host instead of overlaying `libfprint` globally.

Add to `hosts/blackbird/configuration.nix`:

```nix
  # Goodix 27c6:521d is on libfprint's known-unsupported list, so fprintd is
  # pointed at a fork carrying the community goodixtls driver, patched to
  # accept the firmware Windows ships (10034) rather than demanding a
  # downgrade to 10019. Scoped to this host on purpose: the fork is based on
  # libfprint 1.94.1 and must not reach the other hosts via the global overlay.
  services.fprintd = {
    enable = true;
    package = pkgs.fprintd.override {
      libfprint = pkgs.libfprint-goodix-521d;
    };
  };
```

- [ ] **Step 2: Build the host closure**

```bash
cd /home/arosenfeld/Code/nixos
nix build .#nixosConfigurations.blackbird.config.system.build.toplevel 2>&1 | tail -20
```

Expected: PASS.

If fprintd's meson fails looking for libfprint's GObject Introspection data, flip `-Dintrospection=false` to `true` in `packages/libfprint-goodix-521d/default.nix`, add `gobject-introspection` to its `nativeBuildInputs`, and rebuild.

- [ ] **Step 3: Format and commit**

```bash
just fmt
git add hosts/blackbird/configuration.nix
git commit -m "feat(blackbird): enable fprintd with the Goodix 521d driver"
```

- [ ] **Step 4: Deploy**

```bash
just deploy blackbird
```

Runs from raider, which holds the niks3 push token.

- [ ] **Step 5: Verify the daemon sees the device**

```bash
ssh blackbird.bat-boa.ts.net 'systemctl status fprintd --no-pager | head -5; fprintd-list arosenfeld'
```

Expected: fprintd activates and does not report "no devices available".

- [ ] **Step 6: Enrol and verify**

```bash
ssh -t blackbird.bat-boa.ts.net 'fprintd-enroll'
ssh -t blackbird.bat-boa.ts.net 'fprintd-verify'
```

Expected: enroll completes across its scan iterations; verify reports a match.

---

### Task 8: Dual-boot acceptance

The actual success criterion. Everything before this only proves fingerprint works *right now*, which the existing community setup already achieves — the point of this project is that it survives Windows.

**Files:**
- Modify: `docs/superpowers/specs/2026-09-05-goodix-521d-fingerprint-design.md` (final Findings)

**Interfaces:**
- Consumes: a working enrolment from Task 7.
- Produces: pass/fail on the project's goal.

- [ ] **Step 1: Record pre-reboot state**

Re-run the Task 1 probe and note `FIRMWARE` and `PSK_HASH`.

- [ ] **Step 2: Ask the user to boot Windows and use Hello**

This step cannot be automated — it needs someone at the machine. Ask them to boot Windows, use the fingerprint reader at least once, then boot back into NixOS.

- [ ] **Step 3: Re-run the probe**

Compare `FIRMWARE` and `PSK_HASH` against Step 1. Any change identifies exactly what Windows rewrote.

- [ ] **Step 4: Verify without re-enrolling**

```bash
ssh -t blackbird.bat-boa.ts.net 'fprintd-verify'
```

Expected: PASS with no re-flash and no re-enrolment. **That is the goal met.**

If it fails, Step 3's diff says why. If Windows rewrote the PSK, spec Risk 2 has materialised: the "survives dual-boot" bar is not reachable without solving PSK derivation properly, and the honest outcome is to report that rather than paper over it with a re-zeroing hook that reintroduces a treadmill.

- [ ] **Step 5: Record the final outcome and commit**

```bash
cd /home/arosenfeld/Code/nixos
git add docs/superpowers/specs/2026-09-05-goodix-521d-fingerprint-design.md
git commit -m "docs(blackbird): record dual-boot acceptance result for fingerprint"
```

---

## Notes on what is deliberately not here

- **No PAM integration.** `services.fprintd` gives GNOME Settings enrolment and `fprintd-verify`. Wiring fingerprint into login/sudo is a separate decision, and the spec is explicit that this driver should not become sole authentication.
- **No upstreaming.** Out of scope per the spec.
- **No automated test suite.** Tasks 1–6 are investigation; their gate is observed output. Tasks 7–8 carry the real gates: the closure build and the dual-boot round trip.
