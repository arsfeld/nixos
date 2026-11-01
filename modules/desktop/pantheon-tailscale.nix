# Tailscale in Pantheon's Wingpanel: an icon for tailscaled's state, always
# shown, and a popover with an on/off switch and an exit-node picker.
# Package: packages/wingpanel-indicator-tailscale.
# Design: docs/superpowers/specs/2026-11-01-pantheon-tailscale-indicator-design.md
#
# Gated on the two upstream options rather than constellation.*, so the VM test
# (tests/pantheon-tailscale-test.nix) can import this module alone; callPackage
# rather than the flake overlay's attribute for the same reason.
{
  flake.modules.nixos.pantheon-tailscale = {
    key = "modules/desktop/pantheon-tailscale";
    imports = [
      ({
        config,
        lib,
        pkgs,
        ...
      }: {
        config = lib.mkIf (config.services.tailscale.enable && config.services.desktopManager.pantheon.enable) {
          services.desktopManager.pantheon.extraWingpanelIndicators = [
            (pkgs.callPackage ../../packages/wingpanel-indicator-tailscale/package.nix {})
          ];
          # tailscaled lets only root and its operator change prefs, answering
          # 403 to anyone else, and the popover's switch and exit-node picker are
          # such changes. Merges with base's --ssh; tailscaled-set reapplies the
          # list every time tailscaled starts.
          services.tailscale.extraSetFlags = ["--operator=arosenfeld"];
        };
      })
    ];
  };
}
