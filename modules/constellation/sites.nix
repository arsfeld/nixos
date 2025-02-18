{
  config,
  lib,
  ...
}: let
  domain = "arsfeld.one";
  email = "arsfeld@gmail.com";
in {
  options.constellation.sites = {
    enable = lib.mkEnableOption "sites";

    domains = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          domain = lib.mkOption {
            type = lib.types.str;
          };
        };
      });
      default = {};
    };
  };

  config = lib.mkIf config.constellation.sites.enable {
    services.caddy.email = email;
  };
}
