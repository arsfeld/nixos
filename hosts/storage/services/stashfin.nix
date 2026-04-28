{config, ...}: let
  proxyPort = 8096;
  uiPort = 8097;
  hostProxyPort = 18096;
  hostUiPort = 18097;
in {
  sops.secrets."stashfin-env" = {};

  media.containers.stashfin = {
    image = "ghcr.io/feldorn/stash-jellyfin-proxy:latest";
    listenPort = null;
    configDir = "/config";
    environment = {
      STASH_URL = "http://host.containers.internal:9999";
      PROXY_PORT = toString proxyPort;
      UI_PORT = toString uiPort;
      REQUIRE_AUTH_FOR_CONFIG = "true";
    };
    environmentFiles = [
      config.sops.secrets."stashfin-env".path
    ];
    extraOptions = [
      "--add-host=host.containers.internal:host-gateway"
      "--publish=127.0.0.1:${toString hostProxyPort}:${toString proxyPort}"
      "--publish=127.0.0.1:${toString hostUiPort}:${toString uiPort}"
    ];
  };

  services.tsnsrv.services.stashfin = {
    toURL = "http://127.0.0.1:${toString hostProxyPort}";
    funnel = false;
  };
  services.tsnsrv.services.stashfin-ui = {
    toURL = "http://127.0.0.1:${toString hostUiPort}";
    funnel = false;
  };
}
