---
title: "feat: Add web apps constellation module"
type: feat
status: active
date: 2026-03-29
origin: docs/brainstorms/2026-03-29-web-apps-pwa-brainstorm.md
---

# feat: Add Web Apps Constellation Module

## Overview

Create a constellation module (`constellation.webApps`) that turns URLs into standalone desktop apps using Chromium in `--app` mode with Widevine DRM support. Each web app gets its own GNOME launcher entry, icon, and isolated browser profile.

First use case: Crunchyroll (requires Widevine for DRM-protected streaming).

## Problem Statement / Motivation

Some web services (like Crunchyroll) work best as dedicated windows rather than browser tabs. Crunchyroll specifically requires Widevine CDM for DRM playback, which rules out Firefox-based solutions due to unreliable Linux support. A declarative, reusable module lets any desktop host add web apps with a single config block.

(See brainstorm: `docs/brainstorms/2026-03-29-web-apps-pwa-brainstorm.md`)

## Proposed Solution

A new file at `modules/constellation/web-apps.nix` (auto-discovered by haumea) that:

1. Installs Chromium with `enableWidevineCdm = true` via `environment.systemPackages`
2. Generates `xdg.desktopEntries` via `home-manager.users.arosenfeld` for each defined app
3. Fetches app icons at build time with `pkgs.fetchurl`
4. Launches each app with isolated profile, Wayland support, and UX-friendly flags

### Module Interface

```nix
# hosts/raider/configuration.nix
constellation.webApps = {
  enable = true;
  apps = {
    crunchyroll = {
      name = "Crunchyroll";
      url = "https://www.crunchyroll.com";
      icon = pkgs.fetchurl {
        url = "https://www.crunchyroll.com/build/assets/img/favicons/favicon-96x96.png";
        hash = "sha256-XXXX"; # to be determined
      };
      categories = [ "Network" "AudioVideo" ];
    };
  };
};
```

### Module Implementation Sketch

```nix
# modules/constellation/web-apps.nix
{config, pkgs, lib, ...}: let
  cfg = config.constellation.webApps;
  chromium = pkgs.chromium.override {enableWidevineCdm = true;};
in {
  options.constellation.webApps = {
    enable = lib.mkEnableOption "web apps as site-specific Chromium windows";
    apps = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          name = lib.mkOption { type = lib.types.str; };
          url = lib.mkOption { type = lib.types.str; };
          icon = lib.mkOption { type = lib.types.path; };
          categories = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "Network" ];
          };
          extraArgs = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Additional Chromium flags for this app";
          };
        };
      });
      default = {};
    };
  };

  config = lib.mkIf cfg.enable {
    # Guard: only enable on desktop hosts with home-manager
    assertions = [{
      assertion = config.constellation.gnome.enable
              || config.constellation.niri.enable
              || config.constellation.cosmic.enable;
      message = "constellation.webApps requires a desktop environment";
    }];

    environment.systemPackages = [ chromium ];

    home-manager.users.arosenfeld = {
      xdg.desktopEntries = lib.mapAttrs (key: app: {
        name = app.name;
        exec = lib.concatStringsSep " " ([
          "${chromium}/bin/chromium"
          "--ozone-platform=wayland"
          "--user-data-dir=/home/arosenfeld/.config/chromium-apps/${key}"
          "--no-first-run"
          "--no-default-browser-check"
          "--app=${app.url}"
        ] ++ app.extraArgs);
        icon = "${app.icon}";
        terminal = false;
        type = "Application";
        categories = app.categories;
        # StartupWMClass needs verification per-app
        # Chromium --app mode typically uses the URL hostname
      }) cfg.apps;
    };
  };
}
```

## Technical Considerations

### Exec Line Construction
- `.desktop` files do NOT expand `~` — must use absolute path `/home/arosenfeld/.config/chromium-apps/<name>`
- Chromium binary must use full Nix store path (`${chromium}/bin/chromium`) to ensure the Widevine-enabled version is used, not some other `chromium` in PATH
- `--no-first-run` and `--no-default-browser-check` suppress setup dialogs that break the app-like experience

### StartupWMClass (GNOME Dock Integration)
- Without `StartupWMClass`, GNOME won't associate the running window with its dock icon
- Chromium `--app` mode typically sets WM class to the URL hostname (e.g., `crunchyroll.com`)
- This should be verified empirically on first launch, then hardcoded per-app
- Consider adding an optional `wmClass` field to the app submodule for manual override

### Widevine CDM
- `enableWidevineCdm = true` downloads the proprietary Widevine blob (unfree)
- `allowUnfree = true` is already set globally in `modules/constellation/common.nix` — no additional config needed
- Widevine in nixpkgs can occasionally lag behind upstream; runtime DRM failures are silent (Crunchyroll shows "content not available" with no Widevine error)

### Icons
- `pkgs.fetchurl` returns a Nix store path — works directly with `xdg.desktopEntries.icon`
- 256x256 PNG minimum recommended for HiDPI displays; SVG preferred when available
- Icon URL changes or 404s will cause build failures at fetch time

### Profile Isolation
- Each app gets `~/.config/chromium-apps/<name>/` with its own cookies, cache, local storage
- Profiles persist after removing an app from config (no auto-cleanup) — acceptable for personal system
- Multiple apps can run simultaneously as independent Chromium instances

### Interaction with Existing Config
- MangoHud blacklist in `home/home.nix` already includes `"chromium"` — web apps are covered
- No conflict with Zen Browser (different binary, different profiles)
- If user also installs regular Chromium, the Widevine version from this module takes precedence in system packages

## Acceptance Criteria

- [x] `modules/constellation/web-apps.nix` exists and is auto-discovered by haumea
- [x] `constellation.webApps.enable = true` installs Chromium with Widevine
- [x] Each app in `apps` attrset generates a `.desktop` entry visible in GNOME launcher
- [ ] Crunchyroll launches in standalone Chromium window (no tabs/address bar)
- [ ] Widevine DRM works — Crunchyroll video plays without "content not available" errors
- [x] Each app uses an isolated profile directory under `~/.config/chromium-apps/`
- [x] Assertion prevents enabling on non-desktop hosts
- [x] `nix build .#nixosConfigurations.raider.config.system.build.toplevel` succeeds

## MVP

### `modules/constellation/web-apps.nix`

The implementation sketch above is the MVP. The key implementation tasks are:

1. Create the module file with options and config as sketched
2. Find a working icon URL for Crunchyroll and compute its `fetchurl` hash
3. Add `constellation.webApps` config to `hosts/raider/configuration.nix`
4. Build and verify the `.desktop` entry works
5. Verify Widevine DRM plays Crunchyroll content
6. Check `StartupWMClass` with `xprop WM_CLASS` on the running window, add to config

### `hosts/raider/configuration.nix` addition

```nix
constellation.webApps = {
  enable = true;
  apps = {
    crunchyroll = {
      name = "Crunchyroll";
      url = "https://www.crunchyroll.com";
      icon = pkgs.fetchurl {
        url = "<working-icon-url>";
        hash = "sha256-<computed>";
      };
      categories = [ "Network" "AudioVideo" ];
    };
  };
};
```

## Sources

- **Origin brainstorm:** [docs/brainstorms/2026-03-29-web-apps-pwa-brainstorm.md](docs/brainstorms/2026-03-29-web-apps-pwa-brainstorm.md) — Key decisions: Chromium+Widevine engine, constellation module location, isolated profiles, Wayland flags, fetchurl icons
- **Constellation module pattern:** `modules/constellation/development.nix` (enable + sub-options)
- **Home-manager from NixOS module:** `hosts/raider/fontconfig.nix` (precedent for `home-manager.users.arosenfeld` in system config)
- **XDG mime apps pattern:** `home/home.nix:168-177`
