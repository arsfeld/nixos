# macOS-style GameMode indicator in Pantheon's Wingpanel: a controller icon
# while gamemoded has a registered game, with a popover naming the game(s).
# Package: packages/wingpanel-indicator-gamemode.
# Design: docs/superpowers/specs/2026-10-31-pantheon-gamemode-indicator-design.md
#
# Gated on the two upstream options rather than constellation.*, so the VM test
# (tests/pantheon-gamemode-test.nix) can import this module alone; callPackage
# rather than the flake overlay's attribute for the same reason.
{
  flake.modules.nixos.pantheon-gamemode = {
    key = "modules/desktop/pantheon-gamemode";
    imports = [
      ({
        config,
        lib,
        pkgs,
        ...
      }: {
        config = lib.mkIf (config.programs.gamemode.enable && config.services.desktopManager.pantheon.enable) {
          services.desktopManager.pantheon.extraWingpanelIndicators = [
            (pkgs.callPackage ../../packages/wingpanel-indicator-gamemode/package.nix {})
          ];
        };
      })
    ];
  };
}
