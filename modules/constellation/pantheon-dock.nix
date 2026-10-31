# Folder stacks for Pantheon's dock (elementary-dock), modelled on macOS dock
# stacks: Downloads fanned out newest-first, Applications as a grid.
#
# elementary-dock has no applet API, so this carries a local patch. The Vala
# sources live in ./pantheon-dock-stacks/Stacks and are copied into the dock's
# src/Stacks; hooks.patch only adds the gsettings key, the meson hook and the
# stack group in ItemManager. A nixpkgs bump of elementary-dock that breaks
# hooks.patch fails the build, and the patch is rebased on the new source.
#
# Gated on services.desktopManager.pantheon.enable rather than
# constellation.desktop.variant, so a VM test can import this module alone.
# Design: docs/superpowers/specs/2026-10-31-dock-stacks-design.md
{
  config,
  lib,
  ...
}: let
  cfg = config.constellation.desktop.pantheon;
  stacksDir = ./pantheon-dock-stacks;
  inherit (lib.gvariant) mkArray mkTuple;
in {
  options.constellation.desktop.pantheon.dockStacks = lib.mkOption {
    type = lib.types.listOf (lib.types.submodule {
      options = {
        source = lib.mkOption {
          type = lib.types.str;
          description = "Absolute path, a path starting with ~/, or \"applications\".";
        };
        view = lib.mkOption {
          type = lib.types.enum ["fan" "grid"];
          default = "grid";
        };
        sort = lib.mkOption {
          type = lib.types.enum ["date-added" "name"];
          default = "name";
        };
        display = lib.mkOption {
          type = lib.types.enum ["stack" "folder"];
          default = "stack";
        };
      };
    });
    default = [];
    description = "Folder stacks shown on the elementary dock, after the launchers.";
  };

  config = lib.mkIf config.services.desktopManager.pantheon.enable {
    nixpkgs.overlays = [
      (final: prev: {
        pantheon = prev.pantheon.overrideScope (pfinal: pprev: {
          elementary-dock = pprev.elementary-dock.overrideAttrs (old: {
            patches = (old.patches or []) ++ ["${stacksDir}/hooks.patch"];
            postPatch =
              (old.postPatch or "")
              + ''
                cp -r ${stacksDir}/Stacks src/Stacks
                chmod -R u+w src/Stacks
              '';
            doCheck = true;
          });
        });
      })
    ];

    programs.dconf.profiles.user.databases = lib.mkIf (cfg.dockStacks != []) [
      {
        settings."io/elementary/dock".stacks = mkArray (map (s: mkTuple [s.source s.view s.sort s.display]) cfg.dockStacks);
      }
    ];
  };
}
