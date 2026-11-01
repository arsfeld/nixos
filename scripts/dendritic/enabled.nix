# Usage (repo root): nix eval --json --impure --expr 'import ./scripts/dendritic/enabled.nix (builtins.getFlake (toString ./.)) "<host>"'
# Which features each host has on, defaults included: the import list for each
# feature during the dendritic restructure comes from this, not from a grep.
flake: host: let
  c = flake.nixosConfigurations.${host}.config;
  lib = flake.inputs.nixpkgs.lib;
  constellation = lib.mapAttrs (n: v: v.enable) (lib.filterAttrs (n: v: builtins.isAttrs v && v ? enable && builtins.isBool v.enable) c.constellation);
in
  constellation
  // {
    "@blocky" = c.blocky.enable;
    "@check-stock" = c.services.check-stock.enable;
    "@cloudflared" = c.services.cloudflared.enable;
    "@tsnsrv" = c.services.tsnsrv.enable;
    "@tsnsrv-sidecars" = c.virtualisation.oci-sidecars.tsnsrv.enable;
    "@media.services" = builtins.length (builtins.attrNames c.media.services);
    "@media.gateway.services" = builtins.length (builtins.attrNames c.media.gateway.services);
    "@caddy" = c.services.caddy.enable;
    "@pantheon" = c.services.desktopManager.pantheon.enable;
    "@gamemode" = c.programs.gamemode.enable;
  }
