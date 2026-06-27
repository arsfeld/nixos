{
  config,
  lib,
  ...
}: let
  proxyPort = 8096;
  hostProxyPort = 18096;
in {
  sops.secrets."stashfin-env" = {};

  media.services.stashfin = {
    port = proxyPort;
    image = "ghcr.io/arsfeld/stash-jellyfin-proxy:latest";
    # Jellyfin clients (Swiftfin/Infuse/Senplayer) can't follow Authelia's
    # redirect flow; the proxy enforces SJS_USER/SJS_PASSWORD itself.
    bypassAuth = true;
    tailscaleExposed = true;
    container = {
      exposePort = hostProxyPort;
      configDir = "/config";
      environment = {
        STASH_URL = "http://host.containers.internal:9999";
        PROXY_PORT = toString proxyPort;
        REQUIRE_AUTH_FOR_CONFIG = "true";
      };
      environmentFiles = [
        config.sops.secrets."stashfin-env".path
      ];
      extraOptions = [
        "--add-host=host.containers.internal:host-gateway"
      ];
    };
  };
}
