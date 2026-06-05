# Media applications: Ohdio, Qui, Mydia
{
  config,
  lib,
  self,
  ...
}: let
  cfg = config.constellation.mediaApps;
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
  vars = config.media.config;
  pia = config.constellation.pia;
in {
  options.constellation.mediaApps.enable = lib.mkEnableOption "media applications (Ohdio, Qui, Mydia)";

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      sops.secrets.ohdio-env.mode = "0444";
      sops.secrets.qui-oidc-env.mode = "0444";
      sops.secrets.mydia-env.mode = "0444";
    }

    (mkService "ohdio" {
      port = 4000;
      image = "ghcr.io/arsfeld/ohdio:latest";
      container = {
        environment = {
          PHX_HOST = "ohdio.arsfeld.one";
          PORT = "4000";
          MIX_ENV = "prod";
          DATABASE_PATH = "/config/db/ohdio_prod.db";
          STORAGE_PATH = "/config/downloads";
          MAX_CONCURRENT_DOWNLOADS = "3";
          CHECK_ORIGIN = "https://ohdio.arsfeld.one,https://ohdio.bat-boa.ts.net";
        };
        environmentFiles = [
          config.sops.secrets.ohdio-env.path
        ];
      };
      bypassAuth = true;
    })

    (mkService "qui" {
      port = 7476;
      image = "ghcr.io/autobrr/qui";
      container = {
        environment = {
          QUI__HOST = "0.0.0.0";
          QUI__PORT = "7476";
          QUI__OIDC_ENABLED = "true";
          QUI__OIDC_ISSUER = "https://auth.arsfeld.one";
          QUI__OIDC_CLIENT_ID = "qui";
          QUI__OIDC_REDIRECT_URL = "https://qui.arsfeld.one/api/auth/oidc/callback";
          QUI__OIDC_DISABLE_BUILT_IN_LOGIN = "false";
        };
        environmentFiles = [
          config.sops.secrets.qui-oidc-env.path
        ];
        extraOptions = [
          "--no-healthcheck"
        ];
      };
      bypassAuth = true;
    })

    (mkService "mydia" {
      port = 4000;
      image = "ghcr.io/getmydia/mydia:master";
      watchImage = true;
      container = {
        exposePort = 4000;
        mediaVolumes = true;
        network = "host";
        devices = ["/dev/dri:/dev/dri"];
        environment = {
          PHX_HOST = "mydia.arsfeld.one";
          PORT = "4000";
          TV_PATH = "/media/Series";
          MOVIES_PATH = "/media/Movies";
          OIDC_REDIRECT_URI = "https://mydia.arsfeld.one/auth/oidc/callback";
          FLARESOLVERR_ENABLED = "true";
          FLARESOLVERR_URL = "http://localhost:8191";
          ENABLE_REMOTE_ACCESS = "true";
          DOWNLOAD_CLIENT_1_NAME = "rqbit";
          DOWNLOAD_CLIENT_1_TYPE = "rqbit";
          DOWNLOAD_CLIENT_1_ENABLED = "true";
          DOWNLOAD_CLIENT_1_PRIORITY = "1";
          DOWNLOAD_CLIENT_1_HOST = pia.namespaceAddress;
          DOWNLOAD_CLIENT_1_PORT = "3030";
          DOWNLOAD_CLIENT_1_USE_SSL = "false";
          DOWNLOAD_CLIENT_1_DOWNLOAD_DIRECTORY = "${vars.storageDir}/media/Downloads/rqbit";
        };
        environmentFiles = [
          config.sops.secrets.mydia-env.path
        ];
      };
      bypassAuth = true;
    })
  ]);
}
