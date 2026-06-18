# SillyTavern — single-user NSFW chat + image generation frontend.
#
# Text generation uses OpenRouter; image generation uses Stable Horde.
# Both API keys are entered once in SillyTavern's UI and persist in the data
# volume (/var/data/sillytavern-data/.../secrets.json) — no sops wiring.
#
# Access is Tailscale-only: this is a gateway-less container (port = null, so
# no Caddy vhost and nothing on the public *.arsfeld.one cloudflared tunnel),
# published only on loopback and exposed to the tailnet via tsnsrv as
# chat.bat-boa.ts.net (mirrors gatus.nix).
{
  self,
  lib,
  ...
}: let
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
in
  lib.mkMerge [
    (mkService "sillytavern" {
      port = null; # gateway-less: no Caddy vhost, not exposed via cloudflared
      image = "ghcr.io/sillytavern/sillytavern";
      container = {
        # ST stores config under /home/node/app/config; mkService auto-mounts
        # /var/data/sillytavern -> here.
        configDir = "/home/node/app/config";
        environment = {
          SILLYTAVERN_LISTEN = "true";
          SILLYTAVERN_WHITELISTMODE = "false";
          SILLYTAVERN_SECURITYOVERRIDE = "true";
        };
        # Chats, characters, personas, and entered API keys.
        volumes = ["/var/data/sillytavern-data:/home/node/app/data"];
        # Publish on loopback only; tsnsrv reaches the service here.
        extraOptions = ["--publish=127.0.0.1:18000:8000"];
      };
    })

    {
      # Tailnet-only access node -> chat.bat-boa.ts.net. funnel = false keeps it
      # off the public internet. tsnsrv is already enabled on basestar with a
      # default authKeyPath (hosts/basestar/services.nix).
      services.tsnsrv.services.chat = {
        toURL = "http://127.0.0.1:18000";
        funnel = false;
      };
    }
  ]
