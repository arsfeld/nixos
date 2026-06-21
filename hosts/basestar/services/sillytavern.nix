# SillyTavern — single-user NSFW chat + image generation frontend.
#
# Text/image providers, API keys, and prompts are all configured in SillyTavern's
# UI and persist in the data volume (/var/data/sillytavern-data) — no sops wiring.
#
# Declared as a single mkService named "chat" so the gateway emits both access
# paths under that name:
#   - chat.arsfeld.one     — public, via the gateway Caddy vhost reached through
#     basestar's wildcard *.arsfeld.one cloudflared tunnel. bypassAuth omits the
#     gateway's forward_auth to galactica's (offline) Authelia; authentication is
#     instead enforced at Cloudflare's edge by a Zero Trust Access app.
#   - chat.bat-boa.ts.net  — tailnet, via the tsnsrv node from tailscaleExposed.
#
# The service is named "chat" (not "sillytavern") so the subdomains are chat.*;
# the container therefore mounts the existing /var/data/sillytavern* paths
# explicitly (configDir = null) so chats, characters, and entered API keys are
# preserved across the rename.
{
  self,
  lib,
  ...
}: let
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
in
  mkService "chat" {
    port = 8000; # SillyTavern listens on 8000 inside the container
    image = "ghcr.io/sillytavern/sillytavern";
    bypassAuth = true; # auth enforced at Cloudflare's edge, not at the origin
    tailscaleExposed = true; # chat.bat-boa.ts.net
    container = {
      exposePort = 18000; # host port the gateway/tsnsrv proxy to
      configDir = null; # skip the auto /var/data/chat mount; mount the real dirs below
      environment = {
        SILLYTAVERN_LISTEN = "true";
        SILLYTAVERN_WHITELISTMODE = "false"; # behind reverse proxy / tailnet
        SILLYTAVERN_SECURITYOVERRIDE = "true"; # allow running with whitelist off behind a proxy
      };
      volumes = [
        "/var/data/sillytavern:/home/node/app/config" # ST config (preserved)
        "/var/data/sillytavern-data:/home/node/app/data" # chats, characters, API keys (preserved)
      ];
    };
  }
