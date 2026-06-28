# Marinara Engine — standalone local AI chat / roleplay / game engine, run as a
# second frontend alongside SillyTavern ("chat").
#
# Single container (image runs as root, listens on 7860, file-native — no DB).
# Data persists in /var/data/marinara (auto-mounted at /app/data via configDir).
# Providers and API keys are configured in Marinara's own UI and stored encrypted
# in the data volume using ENCRYPTION_KEY (sops marinara-env), so the key must be
# stable across restarts.
#
# Exposed exactly like SillyTavern's "chat":
#   - marinara.arsfeld.one    — public, via the gateway Caddy vhost reached
#     through basestar's wildcard *.arsfeld.one cloudflared tunnel. bypassAuth
#     omits the gateway's forward_auth to galactica's (offline) Authelia;
#     authentication is enforced at Cloudflare's edge by a Zero Trust Access app
#     (must be created BEFORE deploy, mirroring chat.arsfeld.one).
#   - marinara.bat-boa.ts.net — tailnet, via the tsnsrv node from tailscaleExposed.
#
# Marinara's own auth is left open to the private network: it only ever receives
# proxied traffic from the gateway / tsnsrv on basestar's private bridge, so the
# real gates are Cloudflare Access (public) and tailnet membership (private) —
# the same posture as SillyTavern running with its whitelist off behind a proxy.
{config, ...}: {
  sops.secrets."marinara-env" = {
    restartUnits = ["podman-marinara.service"]; # rotate ADMIN_SECRET/ENCRYPTION_KEY without a manual restart
  };

  media.services.marinara = {
    port = 7860; # Marinara listens on 7860 inside the container
    image = "ghcr.io/pasta-devs/marinara-engine"; # :latest (full variant)
    bypassAuth = true; # auth enforced at Cloudflare's edge, not at the origin
    tailscaleExposed = true; # marinara.bat-boa.ts.net
    watchImage = true; # track :latest, restart on new image
    container = {
      exposePort = 17860; # host port the gateway/tsnsrv proxy to
      configDir = "/app/data"; # auto-mounts /var/data/marinara:/app/data
      environmentFiles = [config.sops.secrets."marinara-env".path]; # ENCRYPTION_KEY, ADMIN_SECRET
      environment = {
        MARINARA_DOCKER = "true";
        HOST = "0.0.0.0";
        PORT = "7860";
        DATA_DIR = "/app/data";
        FILE_STORAGE_DIR = "/app/data/storage";
        AUTO_OPEN_BROWSER = "false";
        AUTO_CREATE_DEFAULT_CONNECTION = "false"; # don't seed the OpenRouter Free connection
        ALLOW_UNAUTHENTICATED_PRIVATE_NETWORK = "true"; # trust the proxied private-network traffic
        IP_ALLOWLIST_ENABLED = "false";
        # Behind the proxy Marinara sees the real Host; trust both access origins
        # so its CSRF check accepts form/websocket POSTs from either entrypoint.
        CSRF_TRUSTED_ORIGINS = "https://marinara.arsfeld.one,https://marinara.bat-boa.ts.net";
      };
    };
  };
}
