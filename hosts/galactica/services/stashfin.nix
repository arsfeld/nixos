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
    # Probe-verified.
    # CHOWN: entrypoint chowns /config (chown EPERM seen).
    # DAC_OVERRIDE: writes /config owned by media.
    # FOWNER: precautionary alongside DAC_OVERRIDE (not individually shown necessary).
    # SETUID, SETGID: gosu to PUID/PGID (hardened run failed without them).
    container.hardening.caps = ["CHOWN" "DAC_OVERRIDE" "FOWNER" "SETUID" "SETGID"];
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
