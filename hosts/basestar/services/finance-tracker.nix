# finance-tracker — temporary failover home while galactica is down.
#
# Normally lives on galactica at finance-tracker.arsfeld.one behind Authelia.
# While galactica (and its Authelia at auth.bat-boa.ts.net) is down, we run it
# here exposed only over Tailscale (finance-tracker.bat-boa.ts.net) — the
# tailnet is the auth boundary, so bypassAuth is set. Config/data start fresh
# here (galactica's /var/data/finance-tracker is inaccessible while it's down).
{
  self,
  config,
  lib,
  ...
}: let
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
in
  lib.mkMerge [
    {
      sops.secrets."finance-tracker-env" = {};

      # Publisher credential for posting sync alerts to ntfy.arsfeld.one.
      # Mirrors gatus.nix / galactica's declaration (equal definitions merge).
      sops.secrets."ntfy-publisher-env" = {
        sopsFile = ../../../secrets/sops/ntfy-client.yaml;
        owner = "arosenfeld";
        mode = "0400";
      };
    }

    (mkService "finance-tracker" {
      port = 8080;
      image = "ghcr.io/arsfeld/finance-tracker:latest";
      # Off because the image-watch feature (modules/media/containers.nix) is
      # podman-only, but basestar runs docker (constellation.docker.enable).
      # `podman pull` fails here ("no policy.json") and spams ntfy every 5 min.
      # Pull updates manually: docker pull ghcr.io/arsfeld/finance-tracker:latest
      # && systemctl restart docker-finance-tracker.
      watchImage = false;
      tailscaleExposed = true;
      bypassAuth = true;
      container = {
        environmentFiles = [
          config.sops.secrets."finance-tracker-env".path
          config.sops.secrets."ntfy-publisher-env".path
        ];
        environment = {
          SYNC_SCHEDULE = "0 0 17 */2 * *";
        };
      };
    })
  ]
