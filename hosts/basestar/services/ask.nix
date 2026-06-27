{
  self,
  config,
  lib,
  ...
}: let
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
  backend = config.virtualisation.oci-containers.backend;
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

    # Morphic — ask.arsfeld.one. Reaches the host's system PostgreSQL and native
    # SearXNG via host.containers.internal (provided automatically by podman).
    (mkService "ask" {
      port = 3000;
      image = "ghcr.io/miurla/morphic:latest";
      bypassAuth = true; # auth at the Cloudflare edge (galactica Authelia is down)
      tailscaleExposed = true; # ask.bat-boa.ts.net
      watchImage = true;
      container = {
        configDir = null; # morphic keeps state in postgres, not /config
        environmentFiles = [config.sops.secrets."morphic-env".path];
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
        # Allow the morphic container (podman bridge subnet) to connect with a
        # password to its own database only.
        authentication = lib.mkAfter ''
          host ${dbName} ${dbUser} 10.88.0.0/16 scram-sha-256
        '';
      };
      systemd.services.postgresql.postStart = lib.mkAfter ''
        psql -U postgres -tA <<EOF
          ALTER USER ${dbUser} WITH PASSWORD '$(cat ${config.sops.secrets."morphic-db-password".path})';
        EOF
      '';

      # Morphic starts after its database is up.
      systemd.services."${backend}-ask" = {
        after = ["postgresql.service"];
        wants = ["postgresql.service"];
      };
    }
  ]
