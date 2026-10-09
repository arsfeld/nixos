# Media applications: Ohdio, Qui, Mydia
{
  config,
  lib,
  ...
}: let
  vars = config.media.config;
  pia = config.constellation.pia;
in {
  config = lib.mkMerge [
    {
      sops.secrets.ohdio-env.mode = "0444";
      sops.secrets.qui-oidc-env.mode = "0444";
      sops.secrets.mydia-env.mode = "0444";

      # Settings for the sideloaded Assistant plugin. Mydia applies them at
      # startup (and saves them to its database); the key is the same
      # OpenRouter key stash-identify uses. Users can switch models on the page.
      sops.templates.mydia-assistant-env.content = ''
        PLUGIN_0_SLUG=assistant-openai
        PLUGIN_0_SETTINGS=${builtins.toJSON {
          provider = "OpenRouter";
          api_key = config.sops.placeholder.openrouter-api-key;
          model = "deepseek/deepseek-v4.1-flash";
          model_choice = "Users can choose";
        }}
      '';
      # The env file path never changes, so a new model or key would not
      # restart the container on its own.
      sops.templates.mydia-assistant-env.restartUnits = ["${config.virtualisation.oci-containers.backend}-mydia.service"];

      # Credentials for the garage storage backend (garage.nix).
      sops.templates.mydia-s3-env.content = ''
        STORAGE_BACKEND_1_ACCESS_KEY_ID=${config.sops.placeholder.garage-mydia-access-key-id}
        STORAGE_BACKEND_1_SECRET_ACCESS_KEY=${config.sops.placeholder.garage-mydia-secret-access-key}
      '';
      sops.templates.mydia-s3-env.restartUnits = ["${config.virtualisation.oci-containers.backend}-mydia.service"];
    }

    {
      media.services.ohdio = {
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
      };
    }

    {
      media.services.qui = {
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
      };
    }

    {
      media.services.mydia = {
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
            # Send grabs to the PIA-confined Transmission (galactica's
            # transmission-vpn.nix). mydia is host-networked, so it must address
            # the namespace IP directly: loopback bypasses the DNAT rules the
            # namespace installs on PREROUTING.
            DOWNLOAD_CLIENT_1_NAME = "transmission";
            DOWNLOAD_CLIENT_1_TYPE = "transmission";
            DOWNLOAD_CLIENT_1_ENABLED = "true";
            DOWNLOAD_CLIENT_1_PRIORITY = "1";
            DOWNLOAD_CLIENT_1_HOST = pia.namespaceAddress;
            DOWNLOAD_CLIENT_1_PORT = "9091";
            DOWNLOAD_CLIENT_1_USE_SSL = "false";
            DOWNLOAD_CLIENT_1_AUTO_REMOVE = "true";
            DOWNLOAD_CLIENT_1_REMOVE_COMPLETED = "true";
            DOWNLOAD_CLIENT_1_DOWNLOAD_DIRECTORY = "${vars.storageDir}/media/Downloads";
            # An extra movies library in S3, served by the local Garage
            # (garage.nix), to test mydia's S3 storage end to end.
            STORAGE_BACKEND_1_NAME = "garage";
            STORAGE_BACKEND_1_ENDPOINT = "http://127.0.0.1:3900";
            STORAGE_BACKEND_1_REGION = "garage";
            STORAGE_BACKEND_1_BUCKET = "mydia";
            STORAGE_BACKEND_1_PATH_STYLE = "true";
            LIBRARY_PATH_1_PATH = "s3://garage/movies";
            LIBRARY_PATH_1_NAME = "S3 Movies (test)";
            LIBRARY_PATH_1_TYPE = "movies";
          };
          environmentFiles = [
            config.sops.secrets.mydia-env.path
            config.sops.templates.mydia-assistant-env.path
            config.sops.templates.mydia-s3-env.path
          ];
        };
        bypassAuth = true;
      };
    }
  ];
}
