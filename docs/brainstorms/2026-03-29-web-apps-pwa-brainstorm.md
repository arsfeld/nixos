# Brainstorm: Web Apps / PWAs on Desktop Hosts

**Date**: 2026-03-29
**Status**: Complete

## What We're Building

A constellation module (`constellation.webApps`) that lets any desktop host declaratively define web apps as site-specific browser windows. Each web app gets:

- A standalone Chromium window (no tabs, no address bar) via `--app=<url>`
- Its own `.desktop` entry in the GNOME app launcher
- A custom icon fetched at build time
- Widevine CDM support for DRM-protected content (streaming services)

**First use case**: Crunchyroll (requires Widevine for video playback).

## Why This Approach

- **Chromium with Widevine** is the most reliable DRM path on Linux. Firefox/Zen Widevine support is less consistent.
- **`xdg.desktopEntries`** is an established home-manager pattern already used in this repo.
- **Constellation module** allows any desktop host (raider, g14, striker) to opt in, matching the repo's existing architecture.
- **`fetchurl` for icons** keeps icons up-to-date without committing binary blobs to the repo.

## Key Decisions

1. **Browser engine**: Chromium via nixpkgs with `enableWidevineCdm = true` override
2. **Desktop integration**: home-manager `xdg.desktopEntries` for `.desktop` file generation
3. **Module location**: `modules/constellation/web-apps.nix` — opt-in via `constellation.webApps.enable`
4. **Icon sourcing**: `pkgs.fetchurl` to grab icons at build time from known URLs
5. **First app**: Crunchyroll (`https://www.crunchyroll.com`)
6. **Isolated profiles**: Each web app gets its own `--user-data-dir=~/.config/chromium-apps/<name>` for cookie/session isolation
7. **Wayland by default**: Module adds `--ozone-platform=wayland` flag automatically
8. **Self-contained**: Module installs Chromium with Widevine automatically when enabled

## Proposed Interface

```nix
# In a host configuration (e.g., hosts/raider/configuration.nix)
constellation.webApps = {
  enable = true;
  apps = {
    crunchyroll = {
      name = "Crunchyroll";
      url = "https://www.crunchyroll.com";
      icon = pkgs.fetchurl {
        url = "https://www.crunchyroll.com/build/assets/img/favicons/favicon-96x96.png";
        hash = "sha256-XXXX";  # to be determined
      };
      categories = [ "Network" "AudioVideo" ];
    };
  };
};
```

The module would:
1. Install Chromium with Widevine automatically when enabled
2. Generate `xdg.desktopEntries` for each app with `chromium --ozone-platform=wayland --user-data-dir=~/.config/chromium-apps/<name> --app=<url>`
3. Place fetched icons appropriately
4. Each app runs in an isolated Chromium profile

## Resolved Questions

1. **Per-app Chromium profiles?** Yes — each app gets `--user-data-dir=~/.config/chromium-apps/<name>` for cookie/session isolation.
2. **Wayland flags?** Yes — `--ozone-platform=wayland` added by default since all desktop hosts use Wayland.
3. **Module installs Chromium or expects it?** Self-contained — module installs Chromium with Widevine automatically.

## Alternatives Considered

- **Google Chrome**: Bundles Widevine but is proprietary/unfree. Rejected to avoid `allowUnfree` complexity.
- **Firefox PWA (firefoxpwa)**: Reuses existing browser but Widevine is unreliable. Zen compatibility uncertain.
- **GNOME Web (Epiphany)**: Has "Install as Web App" but no Widevine support on WebKitGTK.
- **Electron wrappers (nativefier)**: Heavy, unmaintained, overkill for URL wrapping.
