{
  self,
  config,
  pkgs,
  lib,
  ...
}: let
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
  # Container units (oci-containers, docker backend) that must wait for the
  # shared "ask" network to exist.
  askNetUnits = ["docker-ask" "docker-webui" "docker-morphic-postgres" "docker-morphic-redis"];
in
  lib.mkMerge [
    {sops.secrets."morphic-env" = {};}

    # Morphic — ask.arsfeld.one. Reaches postgres/redis by name on the "ask"
    # network; reaches host SearXNG via host.docker.internal.
    (mkService "ask" {
      port = 3000;
      image = "ghcr.io/miurla/morphic:latest";
      bypassAuth = true; # auth at the Cloudflare edge (galactica Authelia is down)
      tailscaleExposed = true; # ask.bat-boa.ts.net
      watchImage = true;
      container = {
        configDir = null; # morphic keeps state in postgres, not /config
        network = "ask";
        environmentFiles = [config.sops.secrets."morphic-env".path];
        extraOptions = ["--add-host=host.docker.internal:host-gateway"];
      };
    })

    # Postgres sidecar (no gateway entry, no host port).
    (mkService "morphic-postgres" {
      image = "postgres:17-alpine";
      container = {
        configDir = null;
        network = "ask";
        environmentFiles = [config.sops.secrets."morphic-env".path];
        volumes = ["/var/data/morphic-postgres:/var/lib/postgresql/data"];
      };
    })

    # Redis sidecar (no gateway entry, no host port).
    (mkService "morphic-redis" {
      image = "redis:alpine";
      cmd = ["redis-server" "--appendonly" "yes"];
      container = {
        configDir = null;
        network = "ask";
        volumes = ["/var/data/morphic-redis:/data"];
      };
    })

    {
      # Create the shared docker network with a deterministic bridge name so the
      # firewall rule below can target it; and make every ask-network container
      # start after the network exists. Both are merged into systemd.services
      # via mkMerge (defining systemd.services twice in one attrset is an error).
      systemd.services = lib.mkMerge [
        {
          create-docker-ask-network = {
            description = "Create Docker ask network";
            after = ["docker.service"];
            requires = ["docker.service"];
            wantedBy = ["multi-user.target"];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = ''
              ${pkgs.docker}/bin/docker network inspect ask >/dev/null 2>&1 || \
                ${pkgs.docker}/bin/docker network create \
                  --opt com.docker.network.bridge.name=ask0 ask
            '';
          };
        }
        (lib.genAttrs askNetUnits (_: {
          after = ["create-docker-ask-network.service"];
          requires = ["create-docker-ask-network.service"];
        }))
        {
          # Morphic needs its DB/cache up first; soft dependency (wants, not
          # requires) so a sidecar blip doesn't force-stop the app — Morphic
          # retries connections on its own.
          docker-ask = {
            after = ["docker-morphic-postgres.service" "docker-morphic-redis.service"];
            wants = ["docker-morphic-postgres.service" "docker-morphic-redis.service"];
          };
        }
      ];

      # SearXNG (host :8888) reachable only from the ask network's bridge.
      networking.firewall.interfaces."ask0".allowedTCPPorts = [8888];
    }
  ]
