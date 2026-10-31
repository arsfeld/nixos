# Local patches to Pantheon's dock (elementary-dock), each in its own
# subdirectory. This is the only overlay of the package: a new feature adds its
# patch here instead of overriding elementary-dock a second time, or the two
# patches would fight over the same lines. How to test a change visually:
# ./CLAUDE.md.
#
# Each feature keeps its new Vala sources in ./<feature>/src, copied into the
# dock's src/<Dir>, and its edits to upstream files in ./<feature>/hooks.patch.
# They apply in the order of `features`, and each hooks.patch is generated on
# top of the ones before it.
#
# stacks/: macOS-style folder stacks (Downloads fanned out newest-first,
# Applications as a grid). elementary-dock has no applet API; hooks.patch only
# adds the gsettings key, the meson hook and the stack group in ItemManager.
# Design: docs/superpowers/specs/2026-10-31-dock-stacks-design.md
#
# zoom/: macOS-style magnification under the pointer. Its hooks.patch is larger
# than stacks', because zoom changes how ItemGroup positions every item.
# Design: docs/superpowers/specs/2026-10-31-dock-zoom-design.md
#
# A nixpkgs bump of elementary-dock that breaks a patch fails the build, and
# the patch is rebased on the new source.
#
# Gated on services.desktopManager.pantheon.enable rather than
# constellation.desktop.variant, so a VM test can import this module alone.
{
  config,
  lib,
  ...
}: let
  cfg = config.constellation.desktop.pantheon;
  features = [
    {
      dir = ./stacks;
      dest = "Stacks";
    }
    {
      dir = ./zoom;
      dest = "Zoom";
    }
  ];
  inherit (lib.gvariant) mkArray mkInt32 mkTuple;
in {
  options.constellation.desktop.pantheon = {
    dockStacks = lib.mkOption {
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

    dockZoom = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "macOS-style magnification on the elementary dock.";
      };

      size = lib.mkOption {
        type = lib.types.ints.positive;
        default = 84;
        description = ''
          Logical size in pixels of the icon under the pointer. The dock clamps it
          to what fits in the space above its icons: 104 with the default 48 px icons.
        '';
      };
    };
  };

  config = lib.mkIf config.services.desktopManager.pantheon.enable {
    nixpkgs.overlays = [
      (final: prev: {
        pantheon = prev.pantheon.overrideScope (pfinal: pprev: {
          elementary-dock = pprev.elementary-dock.overrideAttrs (old: {
            patches = (old.patches or []) ++ map (f: "${f.dir}/hooks.patch") features;
            postPatch =
              (old.postPatch or "")
              + lib.concatMapStrings (f: ''
                cp -r ${f.dir}/src src/${f.dest}
                chmod -R u+w src/${f.dest}
              '')
              features;
            doCheck = true;
          });
        });
      })
    ];

    programs.dconf.profiles.user.databases = [
      {
        settings."io/elementary/dock" =
          {
            zoom-enabled = cfg.dockZoom.enable;
            zoom-size = mkInt32 cfg.dockZoom.size;
          }
          // lib.optionalAttrs (cfg.dockStacks != []) {
            stacks = mkArray (map (s: mkTuple [s.source s.view s.sort s.display]) cfg.dockStacks);
          };
      }
    ];
  };
}
