# cylon-link: NixOS on the Valve Steam Link

**Date:** 2026-09-16
**Status:** implemented 2026-09-18. The first boot surfaced several gaps the
design missed; see "Found during bring-up".

## Goal

Run NixOS on a Valve Steam Link and manage it like any other host in this
flake: `just deploy cylon-link`, Tailscale SSH, sops, failure mail, rollback.
The box is meant as a small always-on helper next to galactica's Home
Assistant. What it runs is a separate, later design; this one covers only the
base host.

## Hardware and constraints

Measured on the device on 2026-09-16, booted into djmuted's Debian image.

| | |
|---|---|
| SoC | Marvell Berlin BG2CD (DE3005), Cortex-A9 (`0xc09`), one core visible |
| RAM | 498 MiB (`MemTotal: 510120 kB`) |
| Storage | 1 GB NAND (no mainline driver) — the system lives on a USB stick |
| Network | 100 Mb Ethernet (`pxa168_eth`), Marvell SDIO Wi-Fi/BT (`mwifiex_sdio`, `btmrvl_sdio`) |
| LAN | MAC `e0:31:9e:19:06:5c`, DHCP `192.168.18.34` from the Nokia gateway |
| Stick | Kingston DataTraveler 3.0, 28.8 GiB, serial `1C6F654E4168F290E9213192` |

**The bootloader is signed.** It only loads Valve's kernel, `3.8.13-mrvl`.
What it does allow is running `/steamlink/factory_test/run.sh` from a USB
stick at boot. [djmuted/steamlink-debian](https://github.com/djmuted/steamlink-debian)
uses that to `kexec` into a mainline kernel: `insmod kexec_load.ko` (a
prebuilt module for the 3.8 kernel, no source in that repo), then a
Debian-built `kexec` run inside a `chroot` into the stick. Under the mainline
kernel, Ethernet, USB, Wi-Fi, Bluetooth and serial work; NAND, DMA,
video/audio output, suspend/halt/**reboot** and the RTC do not.

**NixOS binaries cannot run under the stock kernel.** nixpkgs builds glibc
with `--enable-kernel=3.10.0` (`pkgs/development/libraries/glibc/common.nix`),
and 3.8 is older. Anything that executes before the `kexec` must be static
musl. `pkgsCross.armv7l-hf-multiplatform.pkgsStatic.kexec-tools` (2.0.32,
408 KB) builds on raider in 17 minutes, musl cross toolchain included, and was
verified to run on the device.

**nixpkgs' armv7l kernel already supports the board.** `linuxPackages` is
6.18.50, built from `multi_v7_defconfig`, which sets `ARCH_BERLIN`,
`MACH_BERLIN_BG2CD`, `USB_CHIPIDEA_HOST`, `PHY_BERLIN_USB`, `USB_STORAGE`,
`MMC_SDHCI_PXAV3`, `SERIAL_8250_DW` and `KEXEC` built in, and `PXA168_ETH`
and `MWIFIEX_SDIO` as modules. The device tree lands at
`$toplevel/dtbs/berlin2cd-valve-steamlink.dtb`.

**nixpkgs does not cache armv7l.** Every target package is built from source.

## Build benchmark

The same minimal system (openssh, tailscale, stock kernel, same nixpkgs pin)
was built from scratch both ways on 2026-09-16.

| | raider, cross from x86_64 | basestar, native armv7l |
|---|---|---|
| Derivations | 558 | 1416 (includes its own bootstrap) |
| Toolchain | 22 s — cross gcc substituted from `cache.nixos.org` | not finished after 86 min (109 of 122 started); stopped |
| Full system | ~1 h 53 min wall, including two interruptions | not reached |
| Kernel alone | ~75 min (17:45 → 19:00) under a `--cores 4` cap | — |
| Closure | 879 MiB; `zImage` 17 MB | — |

Notes on the numbers:

- basestar (OCI A1, Neoverse-N1) runs AArch32 userspace natively — a static
  armhf binary ran with no binfmt handler registered. Building still needed
  `--option extra-platforms armv7l-linux` and the `gccarch-armv7-a` system
  feature, which nixpkgs requires for armv7l derivations.
- raider ran its first 34 minutes at its configured `max-jobs = 16`,
  `cores = 0`. Claude Code's background-task monitor then killed the build
  twice for "low memory" while earlyoom reported 84% available, so the rest
  ran as a systemd user unit capped at `--max-jobs 8 --cores 4`. Everything
  except the kernel was finished within the first ~35 minutes.

## Decisions

- **Cross-compile on raider.** `nixpkgs.buildPlatform = "x86_64-linux"`,
  `hostPlatform = "armv7l-linux"`. Every derivation is then an x86_64 job, so
  `just deploy` phase 1 picks it up with no justfile change and pushes to
  niks3 as usual. The config still evaluates through
  `.#nixosConfigurations`, so the deploy invariant in `CLAUDE.md` holds.
- **Not built by CI.** CI's build job has a 120-minute timeout, and a
  toolchain bump rebuilds the kernel. raider builds it at deploy time.
- **`autoModules = false` on the kernel.** Still nixpkgs' kernel and
  `multi_v7_defconfig`, which already carry every driver the board needs, but
  without building every other module in the tree. This is the lever on the
  75-minute kernel.
- **Rescue is the stock firmware.** It sits in NAND and always boots. SSH on it
  was enabled persistently by the Debian stick's `enable_ssh.txt`.

## Design

### 1. USB stick layout and boot chain

MBR, two partitions:

- **p1 `CYLON_BOOT`**, 1 GiB, ext3 — made exactly as the Debian image made its
  root (`mkfs.ext3` defaults), which the 3.8 kernel is known to mount. Mounted
  on NixOS at `/boot/steamlink`. Holds only boot material:

  ```
  steamlink/factory_test/run.sh   generated; the only thing the firmware runs
  steamlink/bin/kexec             static musl kexec-tools
  steamlink/kexec_load.ko         pinned, see below
  steamlink/rescue                optional; if present, run.sh does nothing
  nixos/new/{zImage,initrd,dtb,cmdline}    last generation installed
  nixos/good/{zImage,initrd,dtb,cmdline}   last generation that booted OK
  nixos/tried-new, nixos/tried-good        boot-attempt markers
  ```

- **p2 `CYLON_ROOT`**, the rest, ext4 with default features. `/`, including
  `/nix`. The stock kernel never needs to read it.

`kexec_load.ko` is fetched from djmuted/steamlink-debian at commit
`216b58b6e9bb4ba20a9648d1ef089d7b6dbb58df`, path `rootfs/boot/kexec_load.ko`,
sha256 `b1b8a7964a06d7ebcd45170b6565f6d9e348c5fc885eba3ae7fc818f404b1956`
(vermagic `3.8.13-mrvl`, GPL). The copy on the device is byte-identical.

**Boot chain:** Valve bootloader → stock firmware (3.8) → `run.sh` from p1.
`run.sh` is POSIX `sh`, locates p1 from `$0` rather than assuming a mount
point, and does:

```sh
fts-set steamlink.crashcounter 0          # as the Debian image does
[ -e steamlink/rescue ] && exit 0
if   [ -d nixos/new ]  && [ ! -e nixos/tried-new ];  then touch nixos/tried-new;  entry=new
elif [ -d nixos/good ] && [ ! -e nixos/tried-good ]; then touch nixos/tried-good; entry=good
else exit 0                               # nothing left to try: stay on stock firmware
fi
sync
insmod steamlink/kexec_load.ko
steamlink/bin/kexec -c -l nixos/$entry/zImage --initrd nixos/$entry/initrd \
  --dtb nixos/$entry/dtb --command-line "$(cat nixos/$entry/cmdline) cylon.entry=$entry" || exit 1
steamlink/bin/kexec -e
```

`-c` forces the `kexec_load` syscall, the only one `kexec_load.ko` provides.
Any failure before `kexec -e` returns to the stock firmware, which keeps
booting with SSH.

**Install hook.** `boot.loader.external.installHook` runs on every `switch`
and `boot`. It stages `nixos/new.tmp/` from the generation being installed —
`kernel`, `initrd`, the dtb from `hardware.deviceTree.name`, and a `cmdline`
of `init=$toplevel/init` plus `boot.kernelParams` — renames it over
`nixos/new`, removes `nixos/tried-new`, rewrites `run.sh`, `kexec` and
`kexec_load.ko` each via temp file and rename, and `sync`s.

**Boot confirmation.** `cylon-link-boot-ok.service` runs after
`network-online.target` and `tailscaled.service`. It waits up to five minutes
for `tailscale status` to succeed — being deployable is what "booted OK"
means here. On success it reads `cylon.entry` from `/proc/cmdline`:

- `new`: if the `init=` in `nixos/new/cmdline` still matches the running
  one, copy `nixos/new` to `nixos/good` (stage and rename) and remove both
  markers. If it does not — a `switch` landed during the wait — only remove
  `nixos/tried-good`; the newer `new` is tried on the next power cycle.
- `good`: remove `nixos/tried-good` only, so the failed `new` is not retried
  until the next install.

On failure it does nothing, so the next power cycle falls through.

**Outcome:** a broken new generation costs one extra power cycle and comes
back on `good`. If `good` also fails, the box stays on the stock firmware,
reachable over SSH as root with Valve's default password, `steamlink123`;
change it on first use. From there, p1 can be edited. p2's journal cannot be
read, because the stock kernel cannot mount a modern ext4.

### 2. Fleet integration

**Host directory** `hosts/cylon-link/`:

- `configuration.nix` — identity, fleet toggles.
- `hardware.nix` — kernel, device tree, filesystems,
  `boot.kernelParams = ["console=ttyS0,115200n8" "usbcore.autosuspend=-1"]`,
  DHCP on `eth0`.
- `boot/` — `run.sh` template, install hook, `cylon-link-boot-ok.service`.

It lives under `hosts/` because `modules/` is loaded on every host.

**Shared changes:**

- `flake-modules/lib.nix`: add `cylon-link` to `lightHosts` (no home-manager).
- `flake-modules/hosts.nix`: add `ciExcludedHosts = ["cylon-link"]` and filter
  it out of `ciMatrix`, with a comment saying raider builds it at deploy time.
- `modules/constellation/common.nix`: add `constellation.common.minimal`
  (default `false`). When `true`, the large `environment.systemPackages` list
  is replaced by a short set of basic tools and `programs.nix-ld` is skipped.
  Caches and keys, SSH, Tailscale `--ssh`, avahi, zram, earlyoom, GC and the
  journald cap are unchanged.

**Host settings:**

- `nixpkgs.hostPlatform = "armv7l-linux"`, `nixpkgs.buildPlatform = "x86_64-linux"`.
- `constellation.common.minimal = true`.
- `determinate.enable = false` — Determinate Nix ships no armv7l build; the host
  uses nixpkgs' Nix.
- `constellation.virtualization.enable = false`,
  `constellation.netdataClient.enable = false` — too heavy for 500 MB.
- `constellation.email` stays on (default), so failures mail like every host.
- `constellation.sops.enable = true`; `sops.secrets.tailscale-key` from
  `commonSopsFile` feeds `services.tailscale.authKeyFile`, so the box joins the
  tailnet on first boot.
- `nix.settings.max-jobs = 0` — the device never compiles. A path missing from
  the cache fails at once instead of starting a build on one core.
- `boot.kernelPackages = pkgs.linuxPackagesFor (pkgs.linuxPackages.kernel.override {autoModules = false;})`.
  This may require `boot.initrd.includeDefaultModules = false` plus an
  explicit list, and `structuredExtraConfig` for any option a NixOS module
  requires that `autoModules` used to supply.
- `system.stateVersion = "26.05"`.

**Secrets:**

- The host SSH ed25519 key is generated once on raider and stored in
  `secrets/sops/cylon-link-hostkey.yaml`, encrypted to the user key only (like
  `infra.yaml`). It never enters the Nix store.
- Its age form becomes `host_cylon-link` in `.sops.yaml`, is added to the
  `common.yaml` rule, and `common.yaml` is re-encrypted with a non-interactive
  `sops updatekeys`.

**Different from other hosts:**

- Kernel changes need `just boot cylon-link` and a power cycle.
- `just reboot cylon-link` does not work.
- `just deploy-all` includes it, so it adds raider build time there.
- Not tier 1; `weekly-deploy` does not touch it.

### 3. Install, testing, docs

**`just flash-cylon-link DEVICE`**, in the main justfile next to `build-r2s`
and `build-octopi`, run on raider:

1. Refuse unless `DEVICE` is a `/dev/disk/by-id/usb-*` path with nothing
   mounted.
2. Build `.#deployTargets.cylon-link`.
3. Partition: MBR, p1 ext3 `CYLON_BOOT` 1 GiB, p2 ext4 `CYLON_ROOT` rest.
4. Mount p2; `nix copy --no-check-sigs --to "local?root=$mnt" $toplevel`; set
   `$mnt/nix/var/nix/profiles/system` with `nix-env --store`; create
   `$mnt/etc/NIXOS`.
5. Decrypt the host key from `cylon-link-hostkey.yaml` into
   `$mnt/etc/ssh/ssh_host_ed25519_key` (mode 0600) plus its `.pub`.
6. Mount p1 and run the same install logic as the hook, built for the build
   platform, with this toplevel as `new` and no `good`. The first boot's
   fallback is therefore the stock firmware.
7. `sync`, unmount, `udisksctl power-off`.

It wipes the stick, including the current Debian install. The recipe is also
the recovery path. A reflash keeps the host key, and therefore the sops
identity, but Tailscale sees a new node.

**Flake check** `checks.x86_64-linux.cylon-link-boot`: runs the generated
`run.sh` under busybox `sh` in a scratch p1, with stub `insmod`, `kexec` and
`fts-set` that log their arguments, and asserts:

| State | Expected |
|---|---|
| `new` present, no markers | boots `new`, creates `tried-new` |
| `tried-new` present, `good` present | boots `good`, creates `tried-good` |
| both markers present | no `kexec`, exit 0 |
| `rescue` present | no `kexec`, exit 0 |
| `kexec -l` fails | no `kexec -e`, exit 1 |

**First-boot checklist:**

1. Insert the stick, power-cycle. Within a few minutes `cylon-link` appears in
   `tailscale status`; `ssh root@cylon-link.bat-boa.ts.net` works.
2. On the device: `systemctl --failed` is empty;
   `cylon-link-boot-ok.service` succeeded; `nixos/good` exists and no markers
   remain; `free -m` looks sane.
3. A trivial change deploys with `just deploy cylon-link`.
4. The fallback works: `just boot` a generation with the kernel parameter
   `rd.systemd.unit=emergency.target` (this nixpkgs uses the systemd initrd,
   which then waits forever for a console), power-cycle twice, and the box
   returns on `good`. Then boot a working generation again.

**Docs:** `CLAUDE.md` gets the host in "Available Hosts" and a short section on
the boot chain, power-cycling instead of rebooting, the rescue switch, and why
the host is cross-compiled and excluded from CI. `HARDWARE.md` gets its specs.

## To verify during implementation

These are not expected to block, but each is an assumption:

- How the stock firmware mounts a two-partition stick. `run.sh` finding itself
  via `$0` is the hedge; if the firmware only looks at a partition other than
  p1, the layout changes.
  Verified: the firmware mounts p1 at `/mnt/disk` (the ext3 superblock's "Last
  mounted on") and runs `run.sh` from it.
- The shared `tailscale-key` is reusable and makes non-ephemeral nodes, and the
  tailnet ACL lets raider use Tailscale SSH to the new node. Otherwise use a
  dedicated key.
  Wrong on both counts. `tailscale-key` is an OAuth client secret (tsnsrv mints
  `tag:service` nodes with it), and `tailscaled-autoconnect` fails with "oauth
  authkeys require --advertise-tags". The ACL's SSH rules key on `tag:server`,
  which every host carries. The host is now logged in by hand with
  `--advertise-tags=tag:server`, and uses no key at all.
- `boot.loader.external` accepts a hook that also needs `/boot/steamlink`
  mounted, and nothing in NixOS insists on another bootloader.
  Verified: `nixos-rebuild boot` and `just deploy` both stage through the hook.
- `nix-fast-build --systems "x86_64-linux aarch64-linux"` keeps the cross
  toplevel (its `system` attribute should be `x86_64-linux`).
  Verified: `just deploy cylon-link` phase 1 builds and pushes it.
- Whether `ghostty.terminfo` can be included cheaply in the minimal set.
  Verified: 4.9 KiB, no references; included via `pkgsBuildBuild`.
- Whether a hardware watchdog on the SoC can make `reboot` work. Nice to have.
  Not investigated; reboot remains out of scope.
- Valve firmware updates could, in principle, change the `factory_test` hook.
  The box applied one on 2026-09-16 and the hook still worked afterwards.
  Unchanged; nothing to verify.

## Found during bring-up

Everything below surfaced on the device on 2026-09-17/18 and is fixed in
`hosts/cylon-link/`.

- **The first boot hung before mounting root.** The only enabled USB
  controller's PHY takes its reset from `marvell,berlin2-reset`, which the 6.18
  Kconfig builds as a module (`RESET_BERLIN=m`; djmuted's 6.1 kernel has it
  built in). The initrd did not carry it, so the PHY deferred forever, the stick
  never appeared, and nothing reached the network. There was no console to show
  it. What gave it away was reading the stick on raider: `CYLON_ROOT`'s ext4 mount
  count showed only the flash script's mount, and `nixos/tried-new` on p1 showed
  that `run.sh` had reached kexec. Fixed with
  `boot.initrd.kernelModules = ["reset-berlin"]`.
- **Ruled out along the way: kexec placement.** The stock kernel's System RAM
  starts at 16 MB. This kernel decompresses to 43 MB at physical `0x208000`
  (`TEXT_OFFSET` is 0x208000 because multi_v7 includes Meson/QCOM). kexec-tools
  leaves room for the whole decompressed kernel above the zImage, putting the
  initrd at `0x04b47000`, above even the relocated decompressor (about
  `0x3DD0000`). There is no overlap, but a much larger kernel would erode that
  margin.
- **`multi_v7_defconfig` has no netfilter and no TUN.** With `autoModules =
  false`, tailscaled failed on `/dev/net/tun` and `nftables.service` on
  "Protocol not supported". The ruleset and tailscaled's own chains need TUN,
  conntrack, NAT, `nf_tables` (inet/ipv4/ipv6), `ct`, `fib` and masquerade,
  which are now in `structuredExtraConfig`. The rebuild took 21 minutes on
  raider. `NF_CONNTRACK_MARK` is still missing; tailscaled's connmark rules warn
  without it, but they matter only for exit nodes and subnet routes.
- **avahi dies from seccomp on 32-bit ARM.** nixpkgs' unit re-allows
  `setgroups`/`setresuid` after `~@privileged`, but armv7 glibc calls
  `setgroups32`/`setresuid32`. Both are added to its `SystemCallFilter`.
- **tailscaled defaults to iptables**, whose nf_tables-backed `MARK` target needs
  xtables compat modules. It runs with `TS_DEBUG_FIREWALL_MODE=nftables` instead.
- **Tailscale SSH loses exit statuses on this core.** Over multiplexed
  connections it dropped the exit status of fast commands 6 times in 20 (0 of 20
  on galactica, 0 of 20 through OpenSSH). nixos-rebuild multiplexes and aborts
  on a lost status in its `test -f …/nixos-version` check. Tailscale SSH is off
  on this host (`extraSetFlags = ["--ssh=false"]`), and OpenSSH serves port 22
  on the tailnet.
- **Numbers.** A power cycle reaches the network in about 90 seconds, and the
  first boot of a flashed stick in about 3.5 minutes. Installing a new kernel
  over the LAN took 12m42s, while `ext4lazyinit` was still busy with the grown
  root. A userspace-only `just deploy cylon-link` takes about 3 minutes. Under
  6.18, 463 MiB is usable and about 370 MiB is free after boot.
- **Not yet exercised: falling back from a broken `new` to `good`.** The
  no-`good` path is proven: the first, hung boot fell back to the stock
  firmware on the next power cycle, and its SSH worked.

## Rejected alternatives

- **Native builds on basestar.** Correct but far slower: the toolchain alone
  took over 86 minutes, it would recur on every toolchain bump, and it loads
  the public server. It would also need the builder config, `extra-platforms`
  and a CI exclusion.
- **Emulating armv7l on raider with qemu.** Far too slow for a from-source
  closure.
- **Building it in CI.** Slow, and the kernel alone risks the 120-minute
  timeout.
- **A single partition like the Debian image.** The stock kernel would mount
  and write the NixOS root, the whole root would be held to ext4 features 3.8
  understands, and boot state would be mixed into `/`.
- **Keeping Debian as the rescue system.** It would be an unmanaged OS to keep
  patched. The stock firmware is always present and needs nothing.
- **Converting the running Debian in place (nixos-infect style).** Leaves
  Debian's files behind and gives no reproducible install or recovery path.
- **nixpkgs' kernel with `autoModules` on.** Zero config, but it builds nearly
  every module in the tree, which dominates the build.

## Out of scope

Workloads (Zigbee2MQTT, radio bridges, …), Wi-Fi, HDMI/video, making reboot
work, tier membership.
