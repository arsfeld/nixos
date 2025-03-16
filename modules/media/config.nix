{
  config,
  pkgs,
  lib,
  self,
  ...
}: let
  cfg = config.media.config;
in {
  options.media.config = with lib; {
    enable = mkEnableOption "Media config";

    configDir = mkOption {
      type = types.str;
      default = "/var/data";
    };

    dataDir = mkOption {
      type = types.str;
      default = "/mnt/storage";
    };

    storageDir = mkOption {
      type = types.str;
      default = "/mnt/storage";
    };

    puid = mkOption {
      type = types.int;
      default = 5000;
    };

    pgid = mkOption {
      type = types.int;
      default = 5000;
    };

    user = mkOption {
      type = types.str;
      default = "media";
    };

    group = mkOption {
      type = types.str;
      default = "media";
    };

    tz = mkOption {
      type = types.str;
      default = "America/Toronto";
    };

    email = mkOption {
      type = types.str;
      default = "arsfeld@gmail.com";
    };

    domain = mkOption {
      type = types.str;
      default = "arsfeld.one";
    };

    tsDomain = mkOption {
      type = types.str;
      default = "bat-boa.ts.net";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      name = cfg.user;
      group = cfg.group;
      uid = cfg.puid;
      isSystemUser = true;
    };

    users.groups.${cfg.group} = {
      name = cfg.group;
      gid = cfg.pgid;
    };

    age.secrets.cloudflare = {
      file = "${self}/secrets/cloudflare.age";
      owner = "acme";
      group = "acme";
    };

    security.acme.acceptTerms = true;

    security.acme.defaults = {
      email = cfg.email;
      dnsResolver = "1.1.1.1:53";
      dnsProvider = "cloudflare";
      credentialsFile = config.age.secrets.cloudflare.path;
    };
  };
}
