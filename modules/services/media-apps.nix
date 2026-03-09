# Media applications: Ohdio, Qui, Mydia
{
  config,
  lib,
  self,
  ...
}: let
  cfg = config.constellation.mediaApps;
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
in {
  options.constellation.mediaApps.enable = lib.mkEnableOption "media applications (Ohdio, Qui, Mydia)";

  config = lib.mkIf cfg.enable (lib.mkMerge [
    # Ohdio secrets
    {
      age.secrets.ohdio-env = {
        file = "${self}/secrets/ohdio-env.age";
        mode = "444";
      };
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
          config.age.secrets.ohdio-env.path
        ];
      };
      bypassAuth = true;
    })

    # Qui OIDC secrets
    {
      age.secrets.qui-oidc-env = {
        file = "${self}/secrets/qui-oidc-env.age";
        mode = "444";
      };
    }

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
          config.age.secrets.qui-oidc-env.path
        ];
        extraOptions = [
          "--no-healthcheck"
        ];
      };
      bypassAuth = true;
      funnel = true;
    })

    # Mydia secrets
    {
      age.secrets.mydia-env = {
        file = "${self}/secrets/mydia-env.age";
        mode = "444";
      };
    }

    (mkService "mydia" {
      port = 4000;
      image = "ghcr.io/getmydia/mydia:master";
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
          FLARESOLVERR_URL = "http://localhost:8191";
          ENABLE_REMOTE_ACCESS = "true";
        };
        environmentFiles = [
          config.age.secrets.mydia-env.path
        ];
      };
      bypassAuth = true;
    })
  ]);
}
