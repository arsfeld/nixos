# raider: switch from GNOME to COSMIC

## Goal

Replace GNOME with COSMIC on raider. blackbird stays on GNOME.

## Context

`modules/constellation/desktop.nix` already has a `cosmic` variant
(`services.desktopManager.cosmic` + `cosmic-greeter` + Wayland session
variables). The variant enum is exclusive, so switching drops GNOME and GDM.
The upstream COSMIC module enables dconf, gnome-keyring, portals
(`xdg-desktop-portal-cosmic` + `-gtk`) and geoclue itself; the shared module
needs no change.

raider's GPUs (AMD dGPU, Intel iGPU) are well supported by cosmic-comp. The
Steam gamescope session is a separate Wayland session that cosmic-greeter
lists like GDM did.

## Changes

1. **`hosts/raider/configuration.nix`**
   - `constellation.desktop.variant = "cosmic"`.
   - Delete the `programs.dconf.profiles.gdm` block (GDM greeter
     no-idle-suspend policy). GDM no longer exists; suspend stays blocked by
     the masked sleep units and targets in the same file.
2. **`hosts/raider/appearance.nix`** — keep only what GTK apps read under
   COSMIC:
   - Keep `constellation.desktop.gnome.theme` (Yaru-dark), `yaru-theme`, and
     the home-manager `org/gnome/desktop/interface` and
     `org/gnome/desktop/wm/preferences` keys.
   - Delete the `org/gnome/shell/extensions/user-theme` key and the whole
     system dconf database (Logo-menu, dash-to-dock, blur-my-shell).
   - Rewrite the header comment: the file themes GTK apps, not GNOME Shell.
3. **`hosts/raider/fontconfig.nix`** — no functional change. The GTK font
   keys still apply under COSMIC; reword the "GNOME-specific" comment.

COSMIC's own theme, accent, fonts, panel and dock are set by hand in COSMIC
Settings and are not tracked in Nix. No new flake inputs (`cosmic-manager`
was considered and rejected: third-party, and COSMIC's config schema still
moves under the unattended weekly `flake update`).

Out of scope: the shared flatpak list still installs Extension Manager, which
is useless on raider but shared with blackbird; leave it.

## Rollout

raider must **not** be rebooted — background agents are running on it.
Killing the graphical session is acceptable.

1. `just build raider`.
2. `just deploy raider`. `display-manager.service` has
   `restartIfChanged = false`, so the switch leaves the GNOME session up.
3. `sudo systemctl restart display-manager` to replace GDM with
   cosmic-greeter. `KillUserProcesses = false`, so processes outside the
   session (zellij, systemd units) survive; anything parented to a terminal
   window in the GNOME session dies with it.

Rollback: revert the commit, deploy, restart `display-manager` again.

## Verification

- `nix build .#nixosConfigurations.raider.config.system.build.toplevel`
  succeeds.
- After the restart: cosmic-greeter shows the COSMIC and Steam sessions, and
  COSMIC starts.
- GTK/libadwaita apps render Yaru-dark and SF Pro Text.
- `systemctl --user status xdg-desktop-portal-cosmic` is active; file chooser
  works.
- A wallpaper chosen in COSMIC Settings is stored under
  `/run/current-system/sw/share/backgrounds`, not `/nix/store` (GNOME had a
  GC-blank-wallpaper bug that `wallpaper-stable-path` fixes). If COSMIC stores
  store paths, that is a follow-up, not part of this change.
