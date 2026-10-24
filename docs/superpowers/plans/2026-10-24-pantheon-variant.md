# Pantheon Variant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an experimental `pantheon` value to `constellation.desktop.variant`, switch raider to it, and deploy.

**Architecture:** A new `lib.mkIf (cfg.variant == "pantheon")` block in `modules/constellation/desktop.nix`, next to the cosmic and niri blocks. It enables Pantheon with LightDM, two extra Wingpanel indicators, Pantheon Tweaks, and the AppCenter flatpak remote. It also points `DCONF_PROFILE` at a copy of the generated `user` profile that uses a separate user database. raider changes one line.

**Tech Stack:** NixOS 26.05 Pantheon module, nix-flatpak, dconf.

Spec: `docs/superpowers/specs/2026-10-24-pantheon-variant-design.md`

## Global Constraints

- GNOME and Pantheon cannot be enabled together. The variant block must not touch the gnome block.
- `services.flatpak.remotes` must list `flathub` explicitly. Defining the option replaces nix-flatpak's default.
- Do not exclude any stock Pantheon apps.
- Roll out with `just boot raider` and a reboot, never `just deploy raider`. Changing the display manager ends the running session.
- Commit straight to master. Conventional commits. Never mention Claude.

---

### Task 1: Add the `pantheon` variant to the desktop module

**Files:**
- Delete: `hosts/raider/pantheon.nix`
- Modify: `modules/constellation/desktop.nix` (header comment lines 1-6, `variant` enum about line 20, new block after the cosmic block about line 527)

**Interfaces:**
- Produces: `constellation.desktop.variant` accepts `"pantheon"`

- [ ] **Step 1: Confirm the enum rejects the new value (failing test)**

```bash
nix eval --impure --expr 'let f = builtins.getFlake (toString ./.); in (f.nixosConfigurations.raider.extendModules {modules = [{constellation.desktop.variant = f.inputs.nixpkgs.lib.mkForce "pantheon";}];}).config.system.build.toplevel.drvPath'
```

Expected: an error that `"pantheon"` is not one of `"gnome" "cosmic" "niri"`.

- [ ] **Step 2: Delete the dead module**

```bash
git rm hosts/raider/pantheon.nix
```

- [ ] **Step 3: Update the header comment and enum**

Header: `# Selects between GNOME, COSMIC, Niri and Pantheon via constellation.desktop.variant.`
Enum: `type = lib.types.enum ["gnome" "cosmic" "niri" "pantheon"];`

- [ ] **Step 4: Add the variant block after the COSMIC block**

```nix
      # ======== PANTHEON VARIANT ========
      # elementary OS's desktop. Cannot coexist with GNOME in one system
      # (nixpkgs#64611), so it is a variant rather than a second session.
      (lib.mkIf (cfg.variant == "pantheon") (let
        # NixOS writes `user-db:user` into every generated profile, so the
        # database cannot be renamed through programs.dconf.profiles. Copy the
        # generated profile with its own user database instead: Pantheon's
        # theme, font and keybinding writes then land in ~/.config/dconf/pantheon
        # and GNOME's ~/.config/dconf/user is left alone for the switch back.
        # home-manager's dconf activation runs outside the session, without
        # DCONF_PROFILE, so it keeps writing GNOME's database.
        pantheonProfile = pkgs.runCommand "dconf-profile-pantheon" {} ''
          sed 's/^user-db:user$/user-db:pantheon/' \
            ${config.environment.etc.dconf.source}/profile/user > $out
        '';
      in {
        services.xserver.enable = true;
        # Pantheon locks the screen through LightDM; under any other display
        # manager locking from the UI does nothing.
        services.xserver.displayManager.lightdm.enable = true;
        services.desktopManager.pantheon = {
          enable = true;
          extraWingpanelIndicators = with pkgs; [
            # Built with -Dindicator-wingpanel: CPU, RAM, swap, temperature,
            # GPU and network readouts in the top bar.
            pantheon.elementary-monitor
            # Tray icons (Steam, Discord, ...), fed by the service below.
            wingpanel-indicator-namarupa
          ];
        };

        systemd.user.services.indicator-application = {
          description = "Application indicator service for Wingpanel";
          wantedBy = ["graphical-session.target"];
          partOf = ["graphical-session.target"];
          serviceConfig.ExecStart = "${pkgs.indicator-application-gtk3}/libexec/indicator-application/indicator-application-service";
        };

        environment.systemPackages = [pkgs.pantheon-tweaks];

        # Defining remotes replaces nix-flatpak's default, so flathub is
        # listed again. appcenter is elementary's curated Granite app repo.
        services.flatpak.remotes = [
          {
            name = "flathub";
            location = "https://dl.flathub.org/repo/flathub.flatpakrepo";
          }
          {
            name = "appcenter";
            location = "https://flatpak.elementary.io/repo.flatpakrepo";
          }
        ];

        environment.sessionVariables.DCONF_PROFILE = "${pantheonProfile}";
      }))
```

- [ ] **Step 5: Format**

Run: `nix develop -c alejandra -q modules/constellation/desktop.nix`

- [ ] **Step 6: Build with pantheon (the test now passes)**

```bash
nix build --no-link --print-out-paths --impure --expr 'let f = builtins.getFlake (toString ./.); in (f.nixosConfigurations.raider.extendModules {modules = [{constellation.desktop.variant = f.inputs.nixpkgs.lib.mkForce "pantheon";}];}).config.system.build.toplevel'
```

Expected: a store path, with no evaluation warnings about LightDM.

Then check the generated profile:

```bash
cat $(nix eval --raw --impure --expr 'let f = builtins.getFlake (toString ./.); in (f.nixosConfigurations.raider.extendModules {modules = [{constellation.desktop.variant = f.inputs.nixpkgs.lib.mkForce "pantheon";}];}).config.environment.sessionVariables.DCONF_PROFILE')
```

Expected: the first line is `user-db:pantheon`, followed by `file-db:` lines and no `user-db:user`.

- [ ] **Step 7: Confirm GNOME still builds**

Run: `just build raider` (still `variant = "gnome"`). Expected: success.

- [ ] **Step 8: Commit**

```bash
git add modules/constellation/desktop.nix
git commit -m "feat(modules): add an experimental pantheon desktop variant"
```

### Task 2: Switch raider and deploy

**Files:**
- Modify: `hosts/raider/configuration.nix:109-112`

- [ ] **Step 1: Flip the variant**

```nix
    desktop = {
      enable = true;
      # Experimental. "gnome" is the way back: the GNOME settings below and in
      # appearance.nix are inert under Pantheon and kept for that switch.
      variant = "pantheon";
    };
```

- [ ] **Step 2: Build**

Run: `just build raider`. Expected: success.

- [ ] **Step 3: Commit and push**

```bash
git add hosts/raider/configuration.nix
git commit -m "feat(raider): switch to the pantheon desktop variant"
git push origin master
```

- [ ] **Step 4: Stage for next boot**

Run: `just boot raider`. Expected: the closure is pushed and the boot entry is set. The running GNOME session is not touched.

- [ ] **Step 5: Hand the reboot and the post-boot checks to the user**

The reboot ends this session, so the user does it. Post-boot checks are in the spec's Verification section, items 1-7.
