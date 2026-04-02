# Brainstorm: Bazzite-Aligned GNOME Desktop

**Date:** 2026-04-01
**Status:** Draft
**Scope:** `modules/constellation/gnome.nix` + dconf settings

## What We're Building

Align our GNOME desktop configuration with Bazzite's UX philosophy: a more traditional, polished desktop with a branded top-left menu, app replacements for better alternatives, eye-candy animations, and sane keyboard shortcuts. Also add PaperWM for scrollable tiling.

This is NOT a full Bazzite clone. We're cherry-picking the UX improvements that make sense for a NixOS desktop while keeping our own identity (Yaru-purple theme, custom wallpapers, etc.).

## Why This Approach

Bazzite has done significant UX research for their gaming/desktop GNOME variant. Rather than independently discovering the same improvements, we adopt their tested defaults and layer our own preferences on top.

**Core + eye candy scope** was chosen over full alignment because:
- Steam-specific extensions (Add to Steam, Restart To) are already handled by gaming.nix / Steam itself
- Steam sound theme is a matter of taste, not UX improvement
- Numlock state is trivial and can be added later if wanted

## Key Decisions

### Extensions to ADD

| Extension | nixpkgs attr | Purpose |
|---|---|---|
| **Logo Menu** | `logo-menu` | Replace "Activities" text with logo + dropdown menu (top-left corner) |
| **Hot Edge** | `hot-edge` | Bottom screen edge triggers Activities (instead of hot corner) |
| **Caffeine** | `caffeine` | Quick toggle to prevent screen suspend |
| **Compiz Magic Lamp** | `compiz-alike-magic-lamp-effect` | macOS-style minimize animation |
| **PaperWM** | `paperwm` | Scrollable tiling window manager |

### Extensions to REMOVE

| Extension | Reason |
|---|---|
| **gTile** | Replaced by PaperWM |
| **Tiling Shell** | Replaced by PaperWM |
| **Search Light** | Stock GNOME search (Super key) is sufficient |
| **Window Gestures** | Not actively used |

### Extensions to KEEP (not in Bazzite but we want them)

| Extension | Reason |
|---|---|
| **Dash to Dock** | Keep, but note potential PaperWM conflict. Drop if issues arise. |
| **Vitals** | Top-bar system monitoring, quick glance without opening an app |
| **Wallpaper Slideshow** | Auto-rotating wallpapers |
| **Xwayland Indicator** | Useful for debugging X11 vs Wayland issues |
| **AppIndicator** | Both us and Bazzite use this |
| **Blur My Shell** | Both us and Bazzite use this |
| **GSConnect** | Both us and Bazzite use this |
| **User Themes** | Both us and Bazzite use this |

### App Replacements

| Stock App | Replacement | How |
|---|---|---|
| **GNOME Software** | **Bazaar** (already in flatpak list) | Exclude `gnome-software` from GNOME packages |
| **GNOME Extensions App** | **Extension Manager** | Add `com.mattjakeman.ExtensionManager` to flatpak list, exclude `gnome-extensions-app` |

### dconf / GSettings Changes

```nix
# Alt+Tab switches windows (not apps) - more intuitive
"org/gnome/desktop/wm/keybindings" = {
  switch-applications = ["<Super>Tab"];
  switch-applications-backward = ["<Shift><Super>Tab"];
  switch-windows = ["<Alt>Tab"];
  switch-windows-backward = ["<Shift><Alt>Tab"];
};

# Minimize + maximize buttons (stock GNOME only has close)
"org/gnome/desktop/wm/preferences" = {
  button-layout = "appmenu:minimize,maximize,close";
};

# Center new windows
"org/gnome/mutter" = {
  center-new-windows = true;
};

# Directories first in file chooser
"org/gtk/Settings/FileChooser" = {
  sort-directories-first = true;
};
"org/gtk/gtk4/Settings/FileChooser" = {
  sort-directories-first = true;
};

# Create symlink option in Nautilus
"org/gnome/nautilus/preferences" = {
  show-create-link = true;
};

# Disable hot corners (Hot Edge extension replaces this)
"org/gnome/desktop/interface" = {
  enable-hot-corners = false;
};

# Keyboard shortcuts
# Ctrl+Alt+T = Terminal (Ptyxis)
# Ctrl+Shift+Escape = Mission Center
```

### Logo Menu Configuration

```nix
"org/gnome/shell/extensions/Logo-menu" = {
  menu-button-terminal = "ghostty";  # We use Ghostty, not Ptyxis as primary
  menu-button-system-monitor = "missioncenter";
  menu-button-extensions-app = "com.mattjakeman.ExtensionManager.desktop";
  menu-button-software-center = "bazaar";
};
```

## What We're NOT Adopting from Bazzite

- **Steam sound theme** - Personal preference, not UX improvement
- **Add to Steam extension** - Already handled by Steam/gaming setup
- **Restart To extension** - Boot entry switching (niche use case)
- **Bazaar Integration extension** - Shell search provider, not essential
- **Hot corners disabled + Hot Edge only** - We disable hot corners but the Hot Edge is additive
- **Bazzite Shell theme** - We keep Yaru-purple
- **Firefox GNOME theme** - Personal preference
- **Numlock state** - Trivial, not worth the config line
- **Locked GNOME Software settings** - We're removing it entirely

## Open Questions

_None - all questions resolved during brainstorming._

## Resolved Questions

1. **Scope?** Core + eye candy (no Steam-specific or full alignment)
2. **Existing extensions?** Reviewed individually - keep Dash to Dock, Vitals, Wallpaper Slideshow, Xwayland Indicator; drop gTile, Tiling Shell, Search Light, Window Gestures
3. **PaperWM + Dash to Dock conflict?** Add both, drop Dock if conflicts arise
4. **Keyboard shortcuts?** All Bazzite shortcuts: Alt+Tab=windows, Ctrl+Alt+T=terminal, Ctrl+Shift+Esc=Mission Center, minimize/maximize buttons, center new windows, directories first
