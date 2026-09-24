# Workstation dedup: raider and blackbird

## Goal

raider and blackbird each set about twenty of the same top-level options. The
original idea was a new `constellation.workstation` module to hold them. An
audit against the shared modules showed most of that overlap is not a missing
layer:

- Six options restate what `common.nix` or `desktop.nix` already set, or the
  NixOS default.
- Three look shared but carry different values per host.
- The rest have an existing module whose name already describes them.

So this design creates **no new module and no new option**. It deletes the
restatements and moves the real duplicates into `desktop.nix` and `gaming.nix`.

It is a pure refactor. Every host's evaluated system must be unchanged apart
from the flake source path.

## Audit

| Option | raider | blackbird | Already set by |
|---|---|---|---|
| `services.openssh.enable = true` | yes | yes | `common.nix` |
| `time.timeZone = "America/Toronto"` | yes | yes | `common.nix` |
| `i18n.defaultLocale = "en_CA.UTF-8"` | yes | yes | `common.nix` |
| `networking.nftables.enable = true` | yes | yes | `common.nix` |
| `NetworkManager-wait-online.enable = false` | yes | yes | `desktop.nix` shared base |
| `console.keyMap = "us"` | yes | yes | NixOS default |
| Plymouth `bgrt`, `initrd.verbose`, `consoleLogLevel` | yes | yes | nothing |
| xkb `us` / `alt-intl` | yes | yes | nothing |
| `supportedFilesystems = mkForce [...]` | +nfs | same list | nothing |
| `kernelPackages = mkForce cachyos-bore` + `nyx-overlay` import | yes | yes | overrides `gaming.nix`'s xanmod |
| systemd-boot + `canTouchEfiVariables` | limit 5 | limit 4, timeout 10 | nothing |
| `networking.firewall.enable = false` | yes | yes | nothing |
| logind `Login` settings | ignore everything | suspend on lid/power | different values |
| `permittedInsecurePackages` | mbedtls | ventoy | different values; the lists merge |

## Changes

### Deleted from both hosts

Remove the six restatements: openssh, time zone, locale, nftables,
NetworkManager-wait-online, and `console.keyMap`. Each is already supplied at
the same value, so this changes nothing.

### Moved to `desktop.nix` (shared base, every variant)

- `boot.plymouth.enable = true`, `boot.plymouth.theme = "bgrt"`,
  `boot.initrd.verbose = false`, `boot.consoleLogLevel = 0`
- `services.xserver.xkb = { layout = "us"; variant = "alt-intl"; }`
- `boot.supportedFilesystems = ["btrfs" "cifs" "f2fs" "jfs" "ntfs" "reiserfs" "vfat" "xfs"]`,
  as a plain, merging definition with **no `mkForce`**. raider keeps
  `boot.supportedFilesystems = ["nfs"]` for its media mount.

Both hosts carry the comment "Remove zfs support" on `supportedFilesystems`,
and it is stale. The list was evaluated in a scratch copy with the `mkForce`
removed. Nothing contributes zfs; only the derived `btrfs`/`vfat`/`xfs`
remain. So the `mkForce` removes nothing today, and what the list actually does
is *add* cifs, f2fs, jfs, ntfs and reiserfs. Those are removable-media and
network filesystems, which is a desktop concern. The new comment says this, so
the list is not deleted later as dead code.

### Moved to `gaming.nix`

Both gaming hosts force the CachyOS BORE kernel over the module's own xanmod
default, so that default is currently dead code. The policy moves into the
module:

- Take `inputs` as a module argument, and import
  `inputs.chaotic.nixosModules.nyx-overlay` unconditionally. `modules/` is
  loaded into every host, and `inputs` arrives via `specialArgs`, so it is
  usable inside `imports`.
- Set `chaotic.nyx.overlay.enable = lib.mkDefault false` outside the `mkIf`,
  and set it to `true` under `gaming.enable`. The option defaults to `true`
  upstream, so without this the overlay would reach every host in the fleet.
- Under `kernelOptimizations`, replace `linuxPackages_xanmod_latest` with
  `linuxPackages_cachyos-bore`, still at `lib.mkOverride 990`. Move raider's
  BORE comment here: why BORE needs the `cachyos-bore` variant rather than the
  default cachyos-lto (EEVDF), and `cat /proc/sys/kernel/sched_bore` to verify.
- Delete both hosts' `mkForce` kernel line and `nyx-overlay` import. Also delete
  raider's comment about the import.

blackbird's `hardware-configuration.nix` uses `pkgs.nvidia_cachyos-bore`, which
exists only when the overlay is on. That dependency moves from the host's own
import to `gaming.nix`, so a one-line comment next to `package =` records it.

### Left per host

- **`networking.firewall.enable = false`.** Turning off the firewall is a
  security decision, and it should be visible where it applies. Having a
  desktop should not imply it.
- **systemd-boot.** It is two lines, and blackbird's `configurationLimit` and
  `timeout` are tied to its own 500 MB ESP, which its comment explains.
- **logind, `permittedInsecurePackages`.** The values differ.

### Out of scope

`sops.secrets."ntfy-publisher-env"` is copied on raider, blackbird *and*
pegasus. It is not specific to workstations, and belongs to a separate change
if any.

## Verification

This is a refactor, so success means **no change** in what any host evaluates to.

1. Before editing, record `config.system.build.toplevel.drvPath` for each host
   in `ciMatrix`, plus cylon-link.
2. After editing, compare each host's old and new toplevel derivations with
   `nix run nixpkgs#nix-diff`. The only acceptable difference is the flake
   source path (`self`). This must hold for:
   - **raider and blackbird:** the moved options must land at identical values.
   - **every other host:** the unconditional `nyx-overlay` import must stay
     disabled, and `desktop.nix`/`gaming.nix` edits must not leak outside their
     `mkIf`.
3. `just fmt` is clean.
4. `nix flake check` passes.

If `nix-diff` shows a real difference on any host, that is a bug in the move.
Fix the move; do not accept the difference.

No deploy is needed to call it done. Because the result is identical, the next
routine deploy carries it.
