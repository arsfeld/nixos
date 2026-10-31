# Split blackbird's and raider's configuration.nix

## Context

`hosts/blackbird/configuration.nix` is 597 lines and imports only its hardware
and disko files. It mixes the dGPU power-clamp work, ASUS hardware, EasyEffects
audio, the fingerprint reader and suspend policy. `hosts/raider/configuration.nix`
is 443 lines. It is already partly split into twelve sibling files, but Stash,
the niks3 token and auto-upload, the backrest plan, nix-daemon build tuning and
the no-suspend policy are still inline.

`2026-10-31-host-metadata-design.md` set this work aside as a separate piece.
This spec covers it.

Scope is a split inside each host's directory only. The few settings the two
hosts duplicate (the `ntfy-publisher-env` secret, identical Pantheon
`dockStacks`, the firewall turned off) stay duplicated. Lifting them into
`modules/` would touch other hosts and is not part of this work.

## Design

Each concern moves into its own flat sibling file in `hosts/<host>/`, the layout
raider already uses, and is imported from `configuration.nix`. Code and comments
move verbatim. `configuration.nix` keeps the host's identity and the plain
choices: hostname, bootloader, `constellation.*` toggles, kernel parameters,
package list, firewall and `stateVersion`.

### blackbird

| file | contents |
|---|---|
| `nvidia.nix` | `dgpu` binding, `nvidiaPersistenced`, `nvidia-unclamp-tgp`, the Astra Monitor / Executor dconf database, the `nvidia-resume` VT fix |
| `dgpu-power.nix` | the `dgpu-power` script as a `callPackage`-style function taking the nvidia driver package |
| `asus.nix` | supergfxd, asusd fan curves, `asus-shutdown.restartIfChanged`, keyboard-backlight rebind sleep hook |
| `audio.nix` | pipewire, EasyEffects presets and autoload files, the legacy-cleanup activation script, the EasyEffects user service |
| `fingerprint.nix` | fprintd with the goodix-521d libfprint, the gdm-fingerprint PAM module path |
| `power.nix` | the `gsettingsOverrides` binding and both `extraGSettingsOverrides`, power-profiles-daemon, logind lid/power-key suspend |

`configuration.nix` keeps the sops secret, `constellation` block, hostname,
`permittedInsecurePackages`, `systemPackages`, bootloader, `kernelParams`,
NetworkManager and its group, incus, firewall and `stateVersion`.

`dgpu-power` gets its own file because two places use it: `systemPackages` in
`configuration.nix` and the Executor command in `nvidia.nix`. Both call
`pkgs.callPackage ./dgpu-power.nix {nvidia = config.hardware.nvidia.package;}`.
Identical calls give one derivation, so there is a single definition, and
`dgpu-power` stays in its current position in `systemPackages`. If
`nvidia.nix` added it to `systemPackages` itself, the list order would change.

### raider

| file | contents |
|---|---|
| `stash.nix` | the two stash sops secrets, the stashapp-tools/stashPython overlay, `services.stash`, `systemd.services.stash` |
| `niks3.nix` | `inputs.niks3.nixosModules.niks3-auto-upload` import, `niks3-api-token` secret, `services.niks3-auto-upload`, `NIKS3_AUTH_TOKEN_FILE` |
| `backup.nix` | `constellation.backrest` |
| `nix-builds.nix` | binfmt emulation, `extra-platforms` override, `cores = 4`, user slice `MemoryLow`, nix-daemon `MemoryHigh` |
| `no-suspend.nix` | logind ignore settings, the disabled sleep services and targets, `powerManagement.enable`/`powertop`, the `noIdleSuspend` dconf databases |

`configuration.nix` keeps `constellation.sops`, the `ntfy-publisher-env` secret,
`permittedInsecurePackages`, the desktop/gaming/development toggles,
`projectVms`, the netdata label, `media.config`, the Docker storage driver,
`systemPackages`, hostname, bootloader, nfs, the SATA link-power settings,
filebrowser, firewall, `GAMES_DIR` and `stateVersion`.

### Keeping merge order

Imported files' list definitions merge *before* the importing file's own, in
reverse import order (checked with `lib.evalModules`: imports `[a b]` on a host
that also defines the list give `b a host`). Three rules follow:

- A list option defined in only one file can move to another file as a whole.
  The host's subtree stays contiguous among all modules, so the order relative
  to `modules/` does not change.
- A list option is never split across files. `systemPackages` and
  `kernelParams` stay whole in `configuration.nix`.
- raider's `programs.dconf.profiles.user.databases` is defined by both
  `appearance.nix` and (today) `configuration.nix`, last. After the move,
  `no-suspend.nix` has to merge after `appearance.nix`, so it goes *first* in
  `imports`.

The verification below is the backstop for anything these rules miss.

## Verification

This is a pure refactor, so it is proven by comparing before and after:

1. Record `drvPath` of `nixosConfigurations.{blackbird,raider}.config.system.build.toplevel`
   before the change. After it, both must match exactly. That shows the
   closures are unchanged, so nothing needs deploying.
2. If either differs, find the cause with `nix-diff` and fix the placement.
   Do not accept the diff.
3. `just fmt` is clean.

The new files must be `git add`ed (or `git add -N`) before evaluating, or the
flake will not see them.

## Rollout

One commit per host, each verified by its own drvPath:
`refactor(blackbird): split configuration.nix by concern` and
`refactor(raider): split configuration.nix by concern`. Nothing to deploy.
