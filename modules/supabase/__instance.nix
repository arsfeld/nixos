{
  self,
  lib,
  pkgs,
}:
with lib; let
  # Generate environment file for instance
  generateEnvFile = name: instanceCfg: config: let
    port =
      if instanceCfg.port > 0
      then instanceCfg.port
      else (8000 + (stringLength name));
    domain = config.constellation.supabase.defaultDomain;
  in ''
    # Instance-specific configuration
    INSTANCE_NAME=${name}
    INSTANCE_PORT=${toString port}

    # Public URLs
    SUPABASE_PUBLIC_URL=https://${instanceCfg.subdomain}.${domain}
    API_EXTERNAL_URL=https://${instanceCfg.subdomain}.${domain}

    # Ports
    KONG_HTTP_PORT=${toString port}
    STUDIO_PORT=${toString (port + 1)}
    ANALYTICS_PORT=${toString (port + 2)}
    POSTGRES_PORT=${toString (port + 3)}

    # Studio configuration
    STUDIO_DEFAULT_ORGANIZATION=${instanceCfg.subdomain}
    STUDIO_DEFAULT_PROJECT=${instanceCfg.subdomain}

    # Logging
    GOTRUE_LOG_LEVEL=${instanceCfg.logLevel}
    PGRST_LOG_LEVEL=${instanceCfg.logLevel}

    # Storage
    GLOBAL_S3_BUCKET=${instanceCfg.storage.bucket}

    # Site URL for Auth
    GOTRUE_SITE_URL=https://${instanceCfg.subdomain}.${domain}
    SITE_URL=https://${instanceCfg.subdomain}.${domain}

    # Postgres configuration
    POSTGRES_DB=postgres

    # Analytics tokens (these should be randomized per instance in production)
    LOGFLARE_PUBLIC_ACCESS_TOKEN=your-super-secret-and-long-logflare-key-public
    LOGFLARE_PRIVATE_ACCESS_TOKEN=your-super-secret-and-long-logflare-key-private

    # Container prefix
    COMPOSE_PROJECT_NAME=supabase-${name}
  '';

  # Generate tmpfiles rules for an instance
  generateTmpfilesRules = name: instanceCfg: config: let
    baseDir = "/var/lib/supabase-${name}";
    # Create .env file in the store
    envFile = pkgs.writeText "supabase-${name}.env" (generateEnvFile name instanceCfg config);
  in [
    # Create base directory structure
    "d ${baseDir} 0755 root root -"
    "d ${baseDir}/volumes 0755 root root -"
    "d ${baseDir}/volumes/storage 0777 root root -"
    "d ${baseDir}/volumes/db 0755 root root -"
    "d ${baseDir}/volumes/db/data 0777 root root -"
    "d ${baseDir}/volumes/db/init 0755 root root -"
    "d ${baseDir}/volumes/functions 0755 root root -"
    "d ${baseDir}/volumes/functions/hello 0755 root root -"
    "d ${baseDir}/volumes/functions/main 0755 root root -"
    "d ${baseDir}/volumes/logs 0755 root root -"

    # Copy docker-compose.yml
    "L+ ${baseDir}/docker-compose.yml - - - - ${./files/docker-compose.yml}"

    # Copy kong.yml (environment variables will be substituted by Kong at runtime)
    "L+ ${baseDir}/kong.yml - - - - ${./files/volumes/api/kong.yml}"

    # Copy function files
    "L+ ${baseDir}/volumes/functions/hello/index.ts - - - - ${./files/functions/hello/index.ts}"
    "L+ ${baseDir}/volumes/functions/main/index.ts - - - - ${./files/functions/main/index.ts}"

    # Copy database initialization files
    "L+ ${baseDir}/volumes/db/logs.sql - - - - ${./files/volumes/db/logs.sql}"
    "L+ ${baseDir}/volumes/db/pooler.sql - - - - ${./files/volumes/db/pooler.sql}"
    "L+ ${baseDir}/volumes/db/realtime.sql - - - - ${./files/volumes/db/realtime.sql}"
    "L+ ${baseDir}/volumes/db/webhooks.sql - - - - ${./files/volumes/db/webhooks.sql}"
    "L+ ${baseDir}/volumes/db/_supabase.sql - - - - ${./files/volumes/db/_supabase.sql}"
    "L+ ${baseDir}/volumes/db/init/data.sql - - - - ${./files/volumes/db/init/data.sql}"

    # Note: vector.yml must be copied as a real file in ExecStartPre, as Docker cannot mount symlinks

    # Copy .env file
    "L+ ${baseDir}/.env - - - - ${envFile}"
  ];
in {
  inherit generateTmpfilesRules;

  # Generate systemd service for an instance
  generateService = name: instanceCfg: config: let
    containerBackend = config.constellation.supabase.containerBackend;
    containerService = "${containerBackend}.service";
  in {
    description = "Supabase instance: ${name}";
    after = ["network.target" "postgresql.service" containerService];
    wants = ["postgresql.service"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      Type = "simple";
      User = "root";
      Group = "root";
      WorkingDirectory = "/var/lib/supabase-${name}";
      StateDirectory = "supabase-${name}";
      StateDirectoryMode = "0755";

      # Load the complete .env file as environment variables
      EnvironmentFile = config.age.secrets.${instanceCfg.envFile}.path;

      # Use docker-compose to manage the Supabase stack
      ExecStartPre = [
        # Copy vector.yml as a real file (Docker cannot mount symlinks)
        "${pkgs.writeShellScript "setup-vector-${name}" ''
          # Remove existing symlink if present
          rm -f /var/lib/supabase-${name}/volumes/logs/vector.yml
          # Copy as a real file
          cp ${./files/volumes/logs/vector.yml} /var/lib/supabase-${name}/volumes/logs/vector.yml
          chmod 644 /var/lib/supabase-${name}/volumes/logs/vector.yml
        ''}"
        # Pull images
        "${pkgs.writeShellScript "pull-images-${name}" ''
          export PATH=${lib.makeBinPath [pkgs.${containerBackend} pkgs.docker-compose]}:$PATH
          ${
            if containerBackend == "podman"
            then "export DOCKER_HOST=unix:///run/podman/podman.sock"
            else ""
          }
          cd /var/lib/supabase-${name}
          # Source both .env files for docker-compose
          set -a
          source .env
          source ${config.age.secrets.${instanceCfg.envFile}.path}
          # Kong expects these specific variable names
          export SUPABASE_ANON_KEY="$ANON_KEY"
          export SUPABASE_SERVICE_KEY="$SERVICE_ROLE_KEY"
          set +a
          ${pkgs.docker-compose}/bin/docker-compose pull
        ''}"
      ];

      ExecStart = "${pkgs.writeShellScript "start-supabase-${name}" ''
        export PATH=${lib.makeBinPath [pkgs.${containerBackend} pkgs.docker-compose]}:$PATH
        ${
          if containerBackend == "podman"
          then "export DOCKER_HOST=unix:///run/podman/podman.sock"
          else ""
        }
        # Ensure environment variables are available for docker-compose interpolation
        cd /var/lib/supabase-${name}
        # Source the .env files for docker-compose
        set -a
        source .env
        source ${config.age.secrets.${instanceCfg.envFile}.path}
        # Kong expects these specific variable names
        export SUPABASE_ANON_KEY="$ANON_KEY"
        export SUPABASE_SERVICE_KEY="$SERVICE_ROLE_KEY"
        set +a
        ${pkgs.docker-compose}/bin/docker-compose -f docker-compose.yml up
      ''}";
      ExecStop = "${pkgs.writeShellScript "stop-supabase-${name}" ''
        export PATH=${lib.makeBinPath [pkgs.${containerBackend} pkgs.docker-compose]}:$PATH
        ${
          if containerBackend == "podman"
          then "export DOCKER_HOST=unix:///run/podman/podman.sock"
          else ""
        }
        cd /var/lib/supabase-${name}
        ${pkgs.docker-compose}/bin/docker-compose -f docker-compose.yml down
      ''}";

      Restart = "always";
      RestartSec = "10";

      # Security settings (relaxed for container management)
      NoNewPrivileges = false;
      ProtectSystem = false;
      ProtectHome = false;
      PrivateTmp = false;
      ReadWritePaths = ["/var/lib/supabase-${name}" "/var/lib/containers" "/run/${containerBackend}" "/tmp"];
    };
  };
}
