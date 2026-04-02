---
title: Bazzite-Aligned GNOME Desktop
type: feat
status: completed
date: 2026-04-01
origin: docs/brainstorms/2026-04-01-bazzite-gnome-alignment-brainstorm.md
---

# feat: Bazzite-Aligned GNOME Desktop

## Overview

Align our GNOME desktop module (`modules/constellation/gnome.nix`) with Bazzite's tested UX improvements: a branded top-left menu, eye-candy animations, sane keyboard shortcuts, window management tweaks, and better app replacements. Also add PaperWM for scrollable tiling.

This is a single-file change (plus minor host config cleanup) that follows existing patterns in the module.

## Problem Statement / Motivation

Stock GNOME has well-known UX gaps: no system tray (we already fixed), no minimize button, Alt+Tab groups by app not window, no quick app menu, no prevent-sleep toggle. Bazzite has invested significant UX research to address these. Rather than independently discovering the same improvements, we adopt their tested defaults. (see brainstorm: `docs/brainstorms/2026-04-01-bazzite-gnome-alignment-brainstorm.md`)

## Proposed Solution

Modify `modules/constellation/gnome.nix` in four areas:

1. **Extensions** — Add 5, remove 4
2. **dconf settings** — Add keyboard shortcuts, window behavior, file manager tweaks, extension auto-enable, extension config
3. **Package exclusions** — Remove GNOME Software and Extensions App
4. **Flatpak** — Add Extension Manager

## Technical Considerations

### Extension Auto-Enable

Currently extensions are installed but never auto-enabled via dconf. Add `org/gnome/shell.enabled-extensions` with verified UUIDs. This is a **system default** (not locked), so existing users' user-db overrides it — user must manually enable new extensions once after deploy.

### dconf Key Merging

The existing `org/gnome/mutter` attrset already has `experimental-features`. New keys (`center-new-windows`) must be added to the **same attrset**, not a separate one, to avoid silent override.

### GNOME Software Exclusion

`gnome-software` is conditionally enabled by `services.gnome.gnome-software.enable` when flatpak is active. Use both `excludePackages` and explicit `services.gnome.gnome-software.enable = false` for resilience.

### PaperWM Conflicts

PaperWM replaces GNOME's window management paradigm. When active:
- Dash to Dock may render incorrectly (accept, user can disable Dock)
- Magic Lamp minimize animation may not trigger (PaperWM may disable minimize)
- `center-new-windows` is ignored (PaperWM tiles into its scroll strip)
- Hot Edge may behave differently with PaperWM's Activities override

User has accepted these trade-offs. PaperWM will be auto-enabled. If conflicts are severe, user disables PaperWM manually.

### G14 `extraGSettingsOverrides` Conflict

G14 uses deprecated `extraGSettingsOverrides` for `org/gnome/mutter.experimental-features` with a different value than the module's dconf database. This is a **pre-existing bug** — migrate g14's overrides to the module-level dconf database or host-level dconf in this change.

## Acceptance Criteria

- [x] Logo Menu appears in top-left corner with Ghostty as terminal, Mission Center as monitor, Extension Manager and Bazaar in menu
- [x] Hot Edge triggers Activities from bottom screen edge
- [x] Caffeine toggle available in top bar
- [x] Magic Lamp animation on minimize
- [x] PaperWM scrollable tiling is active
- [x] Alt+Tab switches windows (not apps), Super+Tab switches apps
- [x] Window title bars have minimize + maximize + close buttons
- [x] New windows open centered
- [x] File chooser shows directories first
- [x] Nautilus shows "Create Link" option
- [x] Ctrl+Alt+T opens Ghostty
- [x] Ctrl+Shift+Escape opens Mission Center
- [x] GNOME Software is not installed; Bazaar is the app store
- [x] GNOME Extensions App is replaced by Extension Manager (Flatpak)
- [x] gTile, Tiling Shell, Search Light, Window Gestures are removed
- [x] Dash to Dock, Vitals, Wallpaper Slideshow, Xwayland Indicator still present
- [x] `nix build .#nixosConfigurations.raider.config.system.build.toplevel` succeeds
- [x] `nix build .#nixosConfigurations.g14.config.system.build.toplevel` succeeds

## Implementation

All changes are in `modules/constellation/gnome.nix` unless noted.

### Phase 1: Extension Changes

**Add to `lib.optionals config.constellation.gnome.gnomeExtensions` block:**

```nix
gnomeExtensions.logo-menu
gnomeExtensions.hot-edge
gnomeExtensions.caffeine
gnomeExtensions.compiz-alike-magic-lamp-effect
gnomeExtensions.paperwm
```

**Remove from the same block:**

```nix
gnomeExtensions.gtile              # replaced by PaperWM
gnomeExtensions.tiling-shell       # replaced by PaperWM
gnomeExtensions.search-light       # stock GNOME search sufficient
gnomeExtensions.window-gestures    # not used
```

### Phase 2: dconf Settings

Add to the existing `programs.dconf.profiles.user.databases` settings block. **Merge into existing attrsets** where paths overlap.

#### Auto-enable extensions

```nix
"org/gnome/shell" = {
  enabled-extensions = [
    "logomenu@aryan_k"
    "hotedge@jonathan.jdoda.ca"
    "caffeine@patapon.info"
    "compiz-alike-magic-lamp-effect@hermes83.github.com"
    "paperwm@paperwm.github.com"
    "appindicatorsupport@rgcjonas.gmail.com"
    "blur-my-shell@aunetx"
    "dash-to-dock@micxgx.gmail.com"
    "azwallpaper@azwallpaper.gitlab.com"
    "gsconnect@andyholmes.github.io"
    "xwayland-indicator@swsnr.de"
    "Vitals@CoreCoding.com"
    "user-theme@gnome-shell-extensions.gcampax.github.com"
  ];
};
```

#### Window management

```nix
# MERGE into existing "org/gnome/mutter" (already has experimental-features)
"org/gnome/mutter" = {
  experimental-features = ["variable-refresh-rate" "scale-monitor-framebuffer"];
  center-new-windows = true;
};

"org/gnome/desktop/wm/keybindings" = {
  switch-applications = ["<Super>Tab"];
  switch-applications-backward = ["<Shift><Super>Tab"];
  switch-windows = ["<Alt>Tab"];
  switch-windows-backward = ["<Shift><Alt>Tab"];
};

"org/gnome/desktop/wm/preferences" = {
  button-layout = "appmenu:minimize,maximize,close";
};
```

#### Interface

```nix
# MERGE into existing "org/gnome/desktop/interface" (already has gtk-theme, icon-theme)
"org/gnome/desktop/interface" = {
  gtk-theme = config.constellation.gnome.theme.gtk;
  icon-theme = config.constellation.gnome.theme.icon;
  enable-hot-corners = false;
};
```

#### File manager

```nix
# MERGE into existing "org/gnome/nautilus/preferences" (already has default-folder-viewer)
"org/gnome/nautilus/preferences" = {
  default-folder-viewer = "list-view";
  show-create-link = true;
};

"org/gtk/Settings/FileChooser" = {
  sort-directories-first = true;
};

"org/gtk/gtk4/Settings/FileChooser" = {
  sort-directories-first = true;
};
```

#### Keyboard shortcuts

```nix
"org/gnome/settings-daemon/plugins/media-keys" = {
  custom-keybindings = [
    "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/"
    "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom1/"
  ];
};

"org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0" = {
  name = "Terminal";
  command = "ghostty";
  binding = "<Control><Alt>t";
};

"org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom1" = {
  name = "Mission Center";
  command = "missioncenter";
  binding = "<Control><Shift>Escape";
};
```

#### Logo Menu extension config

```nix
"org/gnome/shell/extensions/logo-menu" = {
  menu-button-terminal = "ghostty";
  menu-button-system-monitor = "missioncenter";
  menu-button-extensions-app = "com.mattjakeman.ExtensionManager.desktop";
  menu-button-software-center = "bazaar";
};
```

### Phase 3: Package Exclusions

**Add to `environment.gnome.excludePackages`:**

```nix
gnome-software
```

**Also add explicitly:**

```nix
services.gnome.gnome-software.enable = false;
```

### Phase 4: Flatpak Changes

**Add to `flatpakPackages` default list:**

```nix
"com.mattjakeman.ExtensionManager"
```

### Phase 5: G14 Cleanup (Optional)

**File:** `hosts/g14/configuration.nix`

Migrate `extraGSettingsOverrides` for `org/gnome/mutter.experimental-features` to the module-level dconf database or remove the duplicate. Keep the `text-scaling-factor` override since that's g14-specific.

## Dependencies & Risks

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| PaperWM conflicts with Dash to Dock | Medium | User manually disables Dock if needed |
| PaperWM disables Magic Lamp animation | Medium | Accept — tiling paradigm doesn't use minimize |
| Logo Menu dconf path wrong | Low | Verified: `org/gnome/shell/extensions/logo-menu` from schema XML |
| Extension UUID typos | Low | All UUIDs verified via `nix eval` against nixpkgs |
| Existing users don't get auto-enabled extensions | Expected | Documented — user enables once manually |
| GNOME version bump breaks extensions | Low (future) | Normal nixpkgs maintenance handles this |

## Sources & References

- **Origin brainstorm:** [docs/brainstorms/2026-04-01-bazzite-gnome-alignment-brainstorm.md](docs/brainstorms/2026-04-01-bazzite-gnome-alignment-brainstorm.md) — Key decisions: Core+eye candy scope, keep Dash to Dock/Vitals/Wallpaper Slideshow, add PaperWM, all Bazzite shortcuts
- **Primary file:** `modules/constellation/gnome.nix`
- **Host files:** `hosts/raider/configuration.nix`, `hosts/g14/configuration.nix`
- **Bazzite GNOME config:** [github.com/ublue-os/bazzite](https://github.com/ublue-os/bazzite) — dconf overrides, extension list, app replacements
- **Extension UUIDs:** Verified via `nix eval nixpkgs#gnomeExtensions.<name>.extensionUuid`
- **Logo Menu schema:** `org.gnome.shell.extensions.logo-menu.gschema.xml` (verified from package)
- **Mission Center binary:** `missioncenter` (verified from package)
