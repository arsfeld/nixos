# Global menu for Pantheon: the focused app's menus in Wingpanel, next to
# Applications. Package: packages/pantheon-global-menu (built from
# github.com/arsfeld/pantheon-global-menu), which holds both halves: a Gala
# plugin (focus tracking, AppMenu registrar, typing shortcuts) and the
# Wingpanel indicator.
#
# Gala loads plugins from /run/current-system/sw/lib/gala/plugins (nixpkgs
# patches PLUGINDIR to that), so systemPackages is what installs the plugin;
# /lib is already in pathsToLink. Gala reads plugins only at startup, so a
# change here takes effect at the next login. A crash in the plugin ends the
# Pantheon session.
{
  flake.modules.nixos.pantheon-globalmenu = {
    key = "modules/desktop/pantheon-globalmenu";
    imports = [
      ({
        config,
        lib,
        pkgs,
        ...
      }: let
        globalmenu = pkgs.callPackage ../../packages/pantheon-global-menu/package.nix {};
      in {
        config = lib.mkIf config.services.desktopManager.pantheon.enable {
          services.desktopManager.pantheon.extraWingpanelIndicators = [globalmenu];
          environment.systemPackages = [globalmenu];
        };
      })
    ];
  };
}
