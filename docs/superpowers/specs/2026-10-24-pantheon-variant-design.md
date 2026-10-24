# Pantheon desktop variant on raider

**Host:** raider · **Code:** `modules/constellation/desktop.nix`, `hosts/raider/configuration.nix`

## Goal

Run elementary OS's desktop (Pantheon) on raider as an experiment, with a featureful setup
rather than the stock one: system stats and tray icons in the panel, Pantheon Tweaks, and
AppCenter. Going back to GNOME must be a one-line change.

## Constraints

- **GNOME and Pantheon cannot be enabled in the same system.** nixpkgs documents this
  ([nixpkgs#64611](https://github.com/NixOS/nixpkgs/issues/64611)) and there is no
  workaround. The two cannot share a login screen, so switching means building a
  different system.
- **Pantheon needs LightDM.** Without it, locking the screen from the UI breaks. The
  nixpkgs module enables the Pantheon LightDM greeter by default.
- **elementary Dock 8 has no applets.** Plank, the only dock with applets, is X11-only and
  unmaintained. System stats go in the top panel (Wingpanel) instead.
- **`pantheon-tweaks` is a standalone app now**, not a Switchboard plug.
  `programs.pantheon-tweaks` was removed from nixpkgs.

## Decisions

| Question | Choice |
|---|---|
| How to switch | A `pantheon` value for `constellation.desktop.variant`. Flip it back to `gnome` to return. No specialisation. |
| Settings | Pantheon gets its own dconf user database. GNOME's stays untouched. |
| Dock | Stock elementary Dock on the default `pantheon-wayland` session |
| Extras | Monitor panel indicator, tray icons (namarupa), Pantheon Tweaks, AppCenter with the elementary flatpak remote |
| Not included | Custom Gala settings, hot corners, ported keybindings, trimming the stock app set |

## Changes

### 1. Remove the old module

Delete `hosts/raider/pantheon.nix`. Nothing imports it. It uses removed options
(`gnome.simple-scan`, `services.xserver.displayManager.lightdm`) and predates the variant
design.

### 2. `pantheon` variant in `modules/constellation/desktop.nix`

- Add `"pantheon"` to the `variant` enum, and update the header comment that lists the
  variants.
- Add a `lib.mkIf (cfg.variant == "pantheon")` block next to the other variant blocks:
  - `services.xserver.enable = true;`
  - `services.xserver.displayManager.lightdm.enable = true;`
  - `services.desktopManager.pantheon.enable = true;` with the stock app set. Do not set
    `environment.pantheon.excludePackages`.
  - `services.desktopManager.pantheon.extraWingpanelIndicators =
    [pkgs.pantheon.elementary-monitor pkgs.wingpanel-indicator-namarupa];`.
    `elementary-monitor` is built with `-Dindicator-wingpanel=enabled`, so the same
    package provides both the app and the indicator. It shows CPU, RAM, swap, temperature,
    GPU and network.
  - A user service `indicator-application` that runs
    `${pkgs.indicator-application-gtk3}/libexec/indicator-application/indicator-application-service`.
    Set `wantedBy` and `partOf` to `graphical-session.target`. namarupa needs this service
    to show tray icons.
  - `environment.systemPackages = [pkgs.pantheon-tweaks];`
  - Set `services.flatpak.remotes` (nix-flatpak) to both `flathub`
    (`https://dl.flathub.org/repo/flathub.flatpakrepo`) and `appcenter`
    (`https://flatpak.elementary.io/repo.flatpakrepo`). Defining the option at all
    replaces nix-flatpak's default `[flathub]`, so flathub must be listed explicitly, or
    the shared `flatpakPackages` stop resolving.
  - The dconf isolation described in section 3.

### 3. dconf isolation

NixOS hardcodes `user-db:user` in every generated dconf profile (`mkDconfProfile` in
`nixos/modules/programs/dconf.nix`), so the variant cannot just rename the database in
`programs.dconf.profiles.user`. Instead:

- Build a store file, `pantheonProfile`. It is a `runCommand` that copies
  `${config.environment.etc.dconf.source}/profile/user` with `user-db:user` replaced by
  `user-db:pantheon`. All `file-db:` lines stay, so the system defaults (the Pantheon
  greeter key, the nixos gsettings overrides) still apply.
- Set `environment.sessionVariables.DCONF_PROFILE = "${pantheonProfile}"`. dconf accepts
  an absolute path in `DCONF_PROFILE`.

This works because the file lives in the store, not under `environment.etc`. That means
reading `environment.etc.dconf.source` does not depend on itself.

Inside the Pantheon session, every write goes to `~/.config/dconf/pantheon`. home-manager's
dconf activation (Yaru in `hosts/raider/appearance.nix`, SF Pro fonts in
`hosts/raider/fontconfig.nix`) runs in a system service that has no `DCONF_PROFILE`, so it
keeps writing to GNOME's `~/.config/dconf/user`. Neither file needs gating. As a result,
Pantheon starts with its own stock theme and fonts.

If `DCONF_PROFILE` does not reach the systemd user units that gnome-session starts (Gala,
the settings daemons), add it to `systemd.user.extraConfig` as
`DefaultEnvironment="DCONF_PROFILE=…"` as well. Section 5 checks for this.

### 4. raider

In `hosts/raider/configuration.nix`, set `constellation.desktop.variant = "pantheon"` and
add a comment that `"gnome"` is the way back. Keep the GDM dconf profile, the
`constellation.desktop.gnome.theme` setting and the GNOME dconf keys. They do nothing
without GDM or GNOME Shell, and keeping them makes the switch back a true one-line change.

## Rollout and rollback

Changing the display manager restarts `display-manager.service`, which ends the running
session. Roll out with `just boot raider` and a reboot, not `just deploy raider`.

Rollback:
- **Immediate:** pick the previous generation in the systemd-boot menu (the last 5 are
  kept).
- **Permanent:** set `variant = "gnome"`, run `just boot raider`, and reboot.

`weekly-update` deploys tier 1, which includes raider, so raider runs whichever variant
is committed.

## Verification

Build:
- `just build raider` with `variant = "pantheon"`.
- `just build raider` with `variant = "gnome"` once, without committing it, to confirm the
  switch back still evaluates.

After the reboot:
1. The LightDM greeter offers Pantheon, and the session is Wayland
   (`echo $XDG_SESSION_TYPE`).
2. Wingpanel shows the Monitor indicator and tray icons from a running app (for example
   Steam or Discord).
3. `~/.config/dconf/pantheon` exists. Changing a setting in System Settings updates its
   mtime and leaves `~/.config/dconf/user`'s mtime unchanged.
4. Run `systemctl --user show-environment | grep DCONF_PROFILE`. If the variable is
   missing, apply the fallback from section 3.
5. `flatpak remotes` lists both `flathub` and `appcenter`, and AppCenter opens.
6. Typing uses the `us`/`alt-intl` layout. A fresh dconf database may fall back to a
   different input source. If it does, set `org/gnome/desktop/input-sources` in the
   variant block.
7. After switching back to GNOME, the Yaru theme, SF Pro fonts and extensions are as
   they were.
