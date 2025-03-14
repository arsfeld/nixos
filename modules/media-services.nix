{
  self,
  lib,
  config,
  ...
}: let
  utils = import "${self}/common/site-utils.nix" {inherit config lib;};
  domain = config.mediaServices.domain;
  configs = utils.generateConfigs config.mediaServices.services;
  tsnsrvConfigs = utils.generateTsnsrvConfigs configs config.mediaServices.funnels;
  hosts = utils.generateHosts configs domain config.mediaServices.bypassAuth config.mediaServices.cors;
in
  with lib; {
    options.mediaServices = {
      enable = mkEnableOption "media services";

      services = mkOption {
        type = types.attrsOf types.attrs;
        default = {};
        description = "Media services to enable";
        example = {
          storage = {
            jellyfin = 8096;
          };
          cloud = {
            jellyfin = 8096;
          };
        };
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

      ports = mkOption {
        type = types.attrsOf types.int;
        default = {};
        description = "Ports to use for the media services";
        example = {
          jellyfin = 8096;
        };
      };

      funnels = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Funnel services to enable";
        example = ["jellyfin" "yarr"];
      };

      bypassAuth = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Services to bypass authentication";
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
        default = config.mediaConfig.domain;
        description = "Domain to use for the media services";
        example = "media.example.com";
      };

      email = mkOption {
        type = types.str;
        default = config.mediaConfig.email;
        description = "Email to use for the media services";
        example = "media@example.com";
      };
    };

    config = lib.mkIf config.mediaServices.enable {
      security.acme.certs."${domain}" = {
        extraDomainNames = ["*.${domain}"];
      };

      services.tsnsrv.services = tsnsrvConfigs;

      services.caddy.email = config.mediaServices.email;

      services.caddy.globalConfig = utils.generateCaddyGlobalConfig;

      services.caddy.extraConfig = utils.generateCaddyExtraConfig domain;

      services.caddy.virtualHosts =
        hosts
        // {
          "nextcloud.${domain}" = {
            useACMEHost = domain;
            extraConfig = ''
              rewrite /.well-known/carddav /remote.php/dav
              rewrite /.well-known/caldav /remote.php/dav

              reverse_proxy storage:8099
            '';
          };
        };
    };
  }
