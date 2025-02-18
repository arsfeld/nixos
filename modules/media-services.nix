{
  config,
  pkgs,
  lib,
  self,
  ...
}: {
  options.mediaServices = with lib; {
    enable = mkEnableOption "Media services";

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

  config = lib.mkIf config.mediaServices.enable {
    users.users.${config.mediaServices.user} = {
      name = config.mediaServices.user;
      group = config.mediaServices.group;
      uid = config.mediaServices.puid;
      isSystemUser = true;
    };

    users.groups.${config.mediaServices.group} = {
      name = config.mediaServices.group;
      gid = config.mediaServices.pgid;
    };

    age.secrets.cloudflare = {
      file = "${self}/secrets/cloudflare.age";
      owner = "acme";
      group = "acme";
    };

    security.acme.acceptTerms = true;

    security.acme.defaults = {
      email = config.mediaServices.email;
      dnsResolver = "1.1.1.1:53";
      dnsProvider = "cloudflare";
      credentialsFile = config.age.secrets.cloudflare.path;
    };
  };
}
