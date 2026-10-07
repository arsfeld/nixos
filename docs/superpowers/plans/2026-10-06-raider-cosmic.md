# raider COSMIC Switch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace GNOME with COSMIC on raider without rebooting it.

**Architecture:** Flip `constellation.desktop.variant` to the existing `cosmic`
variant, strip raider's GNOME-Shell-only config, keep GTK theme/font dconf keys.
Activate with `just deploy raider` + a `display-manager` restart.

**Tech Stack:** NixOS flake, home-manager dconf, `just`.

Spec: `docs/superpowers/specs/2026-10-06-raider-cosmic-design.md`

## Global Constraints

- Never reboot raider (background agents are running). Killing the graphical session is fine.
- No changes to `modules/constellation/desktop.nix`; blackbird stays on GNOME.
- No new flake inputs.
- Commit straight to master; conventional commits, scope `raider`.

---

### Task 1: Switch raider's config to COSMIC

**Files:**
- Modify: `hosts/raider/configuration.nix` (variant line ~99; delete GDM dconf block ~381-393)
- Modify: `hosts/raider/appearance.nix` (header comment, user-theme key, system dconf database)
- Modify: `hosts/raider/fontconfig.nix` (comment "GNOME-specific font settings via dconf")

- [ ] **Step 1: Baseline assertion fails before the change**

Run:
```bash
nix eval .#nixosConfigurations.raider.config.services.desktopManager.cosmic.enable
```
Expected: `false`

- [ ] **Step 2: Set the variant**

In `hosts/raider/configuration.nix`: `variant = "gnome";` → `variant = "cosmic";`

- [ ] **Step 3: Delete the GDM greeter policy**

Remove from `hosts/raider/configuration.nix` the comment
"Prevent the GDM greeter's gnome-settings-daemon …" and the whole
`programs.dconf.profiles.gdm.databases = [ … ];` block that follows it.

- [ ] **Step 4: Trim `appearance.nix`**

- Replace the header comment's first line with
  `# GTK look: Ubuntu's Yaru theme for GTK apps, icons and cursor.` and reword
  "GNOME tools rewrite" / "GNOME on Wayland reads" so they say GTK apps read
  these keys from dconf under COSMIC too.
- Delete the `"org/gnome/shell/extensions/user-theme"` attribute.
- Delete the whole `programs.dconf.profiles.user.databases = [ … ];` block
  (and its "Shell extension layout" comment). `lib` becomes unused; drop it
  from the argument set.

- [ ] **Step 5: Reword `fontconfig.nix` comment**

`# GNOME-specific font settings via dconf` →
`# GTK font settings via dconf (read by GTK apps under COSMIC too)`

- [ ] **Step 6: Format and verify evaluation**

```bash
just fmt
nix eval .#nixosConfigurations.raider.config.services.desktopManager.cosmic.enable   # true
nix eval .#nixosConfigurations.raider.config.services.displayManager.gdm.enable      # false
nix eval .#nixosConfigurations.raider.config.services.displayManager.cosmic-greeter.enable  # true
nix eval .#nixosConfigurations.blackbird.config.services.desktopManager.gnome.enable # true
```

- [ ] **Step 7: Build**

Run: `just build raider`
Expected: success.

- [ ] **Step 8: Commit**

```bash
git add hosts/raider/configuration.nix hosts/raider/appearance.nix hosts/raider/fontconfig.nix
git commit -m "feat(raider): switch desktop from GNOME to COSMIC"
```

### Task 2: Activate on raider (no reboot)

- [ ] **Step 1: Deploy**

Run: `just deploy raider`
Expected: switch succeeds; GNOME session stays up (`display-manager` has
`restartIfChanged = false`).

- [ ] **Step 2: Hand off the display-manager restart**

Do not run it from an agent shell parented to the GNOME session. Tell the
user to run `sudo systemctl restart display-manager` (or run it via
`systemd-run` so it isn't killed with the session):
```bash
sudo systemd-run --no-block systemctl restart display-manager
```

- [ ] **Step 3: Verify**

```bash
systemctl status display-manager      # cosmic-greeter
ls /run/current-system/sw/share/wayland-sessions/   # cosmic.desktop, steam
systemctl --user status xdg-desktop-portal-cosmic   # after user logs into COSMIC
```
User confirms: COSMIC session starts, GTK apps show Yaru-dark + SF Pro, file
chooser works. Wallpaper-path check (`grep -r nix/store ~/.config/cosmic/com.system76.CosmicBackground`)
is informational only; a store path there is a follow-up.
