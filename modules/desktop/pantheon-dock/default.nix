# Pantheon's dock with our extras, and the AppCenter patch they lean on.
#
# The dock itself is packages/elementary-dock-extras: the `extras` branch of
# github.com/arsfeld/elementary-dock, a fork of elementary/dock with one commit
# per feature, also published to arsfeld.github.io/pantheon-apt for elementary OS:
#
# - stacks: macOS-style folder stacks (Downloads fanned out newest-first,
#   Applications as a grid). Design: docs/superpowers/specs/2026-10-31-dock-stacks-design.md
# - zoom: magnification under the pointer. Design: docs/superpowers/specs/2026-10-31-dock-zoom-design.md
# - icons: icons stay sharp when zoomed or tilted. Design: docs/superpowers/specs/2026-11-03-dock-sharp-icons-design.md
#
# Changing a feature means a commit on that branch and a rev bump there; how to
# look at it on raider first: ./CLAUDE.md.
#
# appcenter/progress.patch is not the dock's: it makes AppCenter publish its
# jobs, which the Applications stack shows as progress. A nixpkgs bump of
# appcenter that breaks it fails the build, and the patch is rebased.
#
# tests/pantheon-dock-test.nix imports this module alone on plain nixpkgs. Hence
# the gate on services.desktopManager.pantheon.enable rather than
# constellation.desktop.variant, and the overlay calling the package itself
# (with the pantheon scope it overrides) instead of relying on our packages overlay.
{
  flake.modules.nixos.pantheon-dock = {
    key = "modules/desktop/pantheon-dock/default";
    imports = [
      ({
        config,
        lib,
        ...
      }: let
        cfg = config.constellation.desktop.pantheon;
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
                  type = lib.types.enum ["stack" "grid" "folder"];
                  default = "stack";
                  description = "stack: a pile of the newest entries; grid: a 2×2 preview; folder: a static icon.";
                };
              };
            });
            default = [];
            description = ''
              Initial folder stacks on the elementary dock, after the launchers. Dragging a
              folder onto the dock or changing a stack from its right-click menu makes the dock
              save its own list, which then shadows this one;
              `dconf reset /io/elementary/dock/stacks` returns to it.
            '';
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
                elementary-dock = final.callPackage ../../../packages/elementary-dock-extras/package.nix {pantheon = pprev;};
                # appcenter/: publishes AppCenter's install/update/remove jobs on its D-Bus
                # object (JobChanged, GetJobs), for the Applications stack's progress.
                # Design: docs/superpowers/specs/2026-10-31-dock-stacks-progress-design.md
                appcenter = pprev.appcenter.overrideAttrs (old: {
                  patches = (old.patches or []) ++ [./appcenter/progress.patch];
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
      })
    ];
  };
}
