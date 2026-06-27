{
  self,
  config,
  lib,
  ...
}: let
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
  dbName = "morphic";
  dbUser = "morphic";
in
  lib.mkMerge [
    {
      sops.secrets."morphic-env" = {};
      sops.secrets."morphic-db-password" = {
        owner = "postgres";
        group = "postgres";
        mode = "0400";
      };
    }

    # Morphic — ask.arsfeld.one. Runs on docker's default bridge; reaches the
    # host's system PostgreSQL, native Redis, and native SearXNG via
    # host.docker.internal (host-gateway). A custom docker network is avoided
    # on purpose: Docker 29 + nftables on this host fails `docker network
    # create` (missing DOCKER-FORWARD chain), so we use only the default bridge
    # + published host services, which work reliably here.
    (mkService "ask" {
      port = 3000;
      image = "ghcr.io/miurla/morphic:latest";
      bypassAuth = true; # auth at the Cloudflare edge (galactica Authelia is down)
      tailscaleExposed = true; # ask.bat-boa.ts.net
      watchImage = true;
      container = {
        configDir = null; # morphic keeps state in postgres, not /config
        environmentFiles = [config.sops.secrets."morphic-env".path];
        extraOptions = ["--add-host=host.docker.internal:host-gateway"];
      };
    })

    {
      # System PostgreSQL: dedicated morphic database + role (planka pattern).
      services.postgresql = {
        enable = true;
        enableTCPIP = true;
        ensureDatabases = [dbName];
        ensureUsers = [
          {
            name = dbUser;
            ensureDBOwnership = true;
          }
        ];
        # Allow the morphic container (docker bridge subnet) to connect with a
        # password to its own database only.
        authentication = lib.mkAfter ''
          host ${dbName} ${dbUser} 172.16.0.0/12 scram-sha-256
        '';
      };
      systemd.services.postgresql.postStart = lib.mkAfter ''
        psql -U postgres -tA <<EOF
          ALTER USER ${dbUser} WITH PASSWORD '$(cat ${config.sops.secrets."morphic-db-password".path})';
        EOF
      '';

      # Native Redis for Morphic chat history / sharing. Bound to loopback and
      # the docker0 gateway so the container can reach it; firewalled to the
      # bridge only.
      services.redis.servers.morphic = {
        enable = true;
        port = 6379;
        bind = "127.0.0.1 172.17.0.1";
        settings = {
          protected-mode = "no";
          appendonly = "yes";
        };
      };
      # The docker0 gateway IP only exists once docker is up.
      systemd.services.redis-morphic = {
        after = ["docker.service"];
        requires = ["docker.service"];
      };

      # Morphic starts after its DB + cache are up.
      systemd.services.docker-ask = {
        after = ["postgresql.service" "redis-morphic.service"];
        wants = ["postgresql.service" "redis-morphic.service"];
      };

      # System postgres/redis/searxng reachable only from the docker bridge.
      networking.firewall.interfaces."docker0".allowedTCPPorts = [5432 6379 8888];
    }
  ]
