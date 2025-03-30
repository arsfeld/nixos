{
  self,
  lib,
  config,
  ...
}:
with lib; let
  utils = import "${self}/modules/media/__utils.nix" {inherit config lib;};
  nameToPort = import "${self}/common/nameToPort.nix";
  cfg = config.media.gateway;
  _config = config;
  domain = cfg.domain;
  tsnsrvConfigs = utils.generateTsnsrvConfigs {
    services = cfg.services;
    funnels = cfg.funnels;
  };
  hosts = utils.generateHosts {
    services = cfg.services;
    domain = domain;
    bypassAuth = cfg.bypassAuth;
    insecureTls = cfg.insecureTls;
    cors = cfg.cors;
  };
in {
  options.media.gateway = mkOption {
    type = types.submodule ({config, ...}: {
      options = {
        enable = mkEnableOption "media gateway";

        services = mkOption {
          default = {};
          description = "Services to expose to the gateway";
          example = {
            jellyfin = {
              host = "storage";
              port = 8096;
            };
          };
          type = types.attrsOf (types.submodule ({config, ...}: {
            options = {
              enable = mkOption {
                type = types.bool;
                default = true;
                description = "Enable the media service";
              };
              name = mkOption {
                type = types.str;
                default = config._module.args.name;
                description = "Name of the media service";
                example = "jellyfin";
              };
              host = mkOption {
                type = types.str;
                default = _config.networking.hostName;
                description = "Host to use for the media services";
                example = "storage";
              };
              port = mkOption {
                type = types.int;
                default = nameToPort config.name;
                description = "Port to use for the media services";
              };
            };
          }));
        };

        authHost = mkOption {
          type = types.str;
          default = "cloud.bat-boa.ts.net";
          description = "Host to use for the media services";
          example = "media.example.com";
        };

        authPort = mkOption {
          type = types.int;
          default = 443;
          description = "Port to use for the media services";
          example = 443;
        };

        funnels = mkOption {
          type = types.listOf types.str;
          default = [];
          description = "Funnel services to enable using tsnsrv";
          example = ["jellyfin" "yarr"];
        };

        bypassAuth = mkOption {
          type = types.listOf types.str;
          default = [];
          description = "Services to bypass authentication";
          example = ["jellyfin" "yarr"];
        };

        insecureTls = mkOption {
          type = types.listOf types.str;
          default = [];
          description = "Services to allow insecure TLS";
          example = ["jellyfin" "yarr"];
        };

        cors = mkOption {
          type = types.listOf types.str;
          default = [];
          description = "Services to allow CORS";
          example = ["jellyfin" "yarr"];
        };

        domain = mkOption {
          type = types.str;
          default = _config.media.config.domain;
          description = "Domain to use for the media services";
          example = "media.example.com";
        };

        email = mkOption {
          type = types.str;
          default = _config.media.config.email;
          description = "Email to use for the media services";
          example = "media@example.com";
        };
      };
    });
  };

  config = lib.mkIf cfg.enable {
    security.acme.certs."${domain}" = {
      extraDomainNames = ["*.${domain}"];
    };

    services.tsnsrv.services = tsnsrvConfigs;

    services.caddy.email = cfg.email;

    services.caddy.globalConfig = utils.generateCaddyGlobalConfig;

    services.caddy.extraConfig = utils.generateCaddyExtraConfig domain;

    services.caddy.virtualHosts = hosts;
  };
}
