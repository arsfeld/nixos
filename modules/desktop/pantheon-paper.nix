# PaperWM-style scrolling tiling for Pantheon: each workspace on the primary
# monitor is a horizontal strip of columns that scrolls to follow focus.
# Package: packages/pantheon-paper (github.com/arsfeld/pantheon-paper), a Gala
# plugin. Design: docs/superpowers/specs/2026-11-12-pantheon-paper-design.md.
#
# Gala loads plugins from /run/current-system/sw/lib/gala/plugins, so
# systemPackages installs the plugin; extraGSettingsOverridePackages puts its
# keybinding schema where Gala looks (NIX_GSETTINGS_OVERRIDES_DIR). Gala reads
# plugins only at startup, so a change takes effect at the next login, and a
# crash in the plugin ends the Pantheon session.
#
# The plugin's keys (io.github.arsfeld.paper.keybindings) take over bindings
# Pantheon already uses. These are Pantheon's own values, which differ from
# GNOME's: check with XDG_CURRENT_DESKTOP=Pantheon, or run
# `just pantheon::paper-keys-check`, which fails on any clash. Changed here as
# system defaults (a value in the user's own dconf database still wins):
#   Super+Left/Right       switched workspaces; workspace switching moves to
#                          Ctrl+Super+Left/Right, which was half-screen tiling
#                          (strips replace it, so it is cleared; edge tiling off)
#   Super+Down             also opened the multitasking view, which keeps Super+S
#   Super+Shift+arrows     move-to-monitor
# Super+F (picture-in-picture) and Super+O (rotation lock) stay Pantheon's:
# the plugin's full-width toggle is Super+M and barf is Super+U instead.
{
  flake.modules.nixos.pantheon-paper = {
    key = "modules/desktop/pantheon-paper";
    imports = [
      ({
        config,
        lib,
        pkgs,
        ...
      }: let
        cfg = config.constellation.desktop.paper;
        paper = pkgs.callPackage ../../packages/pantheon-paper/package.nix {};
        none = lib.gvariant.mkEmptyArray lib.gvariant.type.string;
      in {
        options.constellation.desktop.paper.enable = lib.mkOption {
          type = lib.types.bool;
          default = config.constellation.desktop.variant == "pantheon";
          defaultText = lib.literalExpression ''config.constellation.desktop.variant == "pantheon"'';
          description = "PaperWM-style scrolling tiling in Pantheon (the pantheon-paper Gala plugin).";
        };

        config = lib.mkIf (config.services.desktopManager.pantheon.enable && cfg.enable) {
          environment.systemPackages = [paper];
          services.desktopManager.pantheon.extraGSettingsOverridePackages = [paper];

          programs.dconf.profiles.user.databases = [
            {
              settings = {
                "org/gnome/mutter".edge-tiling = false;
                "org/gnome/mutter/keybindings" = {
                  toggle-tiled-left = none;
                  toggle-tiled-right = none;
                };
                "org/gnome/desktop/wm/keybindings" = {
                  switch-to-workspace-left = ["<Control><Super>Left"];
                  switch-to-workspace-right = ["<Control><Super>Right"];
                  move-to-monitor-left = none;
                  move-to-monitor-right = none;
                  move-to-monitor-up = none;
                  move-to-monitor-down = none;
                };
                "io/elementary/desktop/wm/keybindings".toggle-multitasking-view = ["<Super>s"];
              };
            }
          ];
        };
      })
    ];
  };
}
