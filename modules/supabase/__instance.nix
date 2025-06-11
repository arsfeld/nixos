{
  self,
  lib,
  pkgs,
}:
with lib; let
  # Kong configuration file
  kongConfig = pkgs.writeText "kong.yml" (builtins.readFile ./files/kong.yml);

  # Generate Docker Compose configuration using Nix syntax
  generateDockerCompose = name: instanceCfg: config: let
    port =
      if instanceCfg.port > 0
      then instanceCfg.port
      else (8000 + (stringLength name));
    domain = config.constellation.supabase.defaultDomain;

    # Define each service as a Nix attribute set (without mkIf)
    kongService = {
      image = "kong:2.8.1";
      restart = "unless-stopped";
      ports = ["${toString port}:8000"];
      environment = {
        KONG_DATABASE = "off";
        KONG_DECLARATIVE_CONFIG = "/var/lib/kong/kong.yml";
        KONG_DNS_ORDER = "LAST,A,CNAME";
        KONG_PLUGINS = "request-transformer,cors,key-auth,acl";
        SUPABASE_ANON_KEY = "\${SUPABASE_ANON_KEY}";
      };
      volumes = ["./kong.yml:/var/lib/kong/kong.yml:ro"];
    };

    authService = {
      image = "supabase/gotrue:v2.174.0";
      depends_on = ["db"];
      restart = "unless-stopped";
      environment = {
        GOTRUE_API_HOST = "0.0.0.0";
        GOTRUE_API_PORT = "9999";
        GOTRUE_DB_DRIVER = "postgres";
        GOTRUE_DB_DATABASE_URL = "postgres://supabase_auth_admin:\${DB_PASSWORD}@db:5432/postgres";
        GOTRUE_LOG_LEVEL = instanceCfg.logLevel;
        GOTRUE_SITE_URL = "https://${instanceCfg.subdomain}.${domain}";
        GOTRUE_URI_ALLOW_LIST = "*";
        GOTRUE_JWT_EXP = "3600";
        GOTRUE_JWT_DEFAULT_GROUP_NAME = "authenticated";
        GOTRUE_JWT_SECRET = "\${JWT_SECRET}";
        API_EXTERNAL_URL = "https://${instanceCfg.subdomain}.${domain}";
      };
    };

    restService = {
      image = "postgrest/postgrest:v12.2.12";
      depends_on = ["db"];
      restart = "unless-stopped";
      environment = {
        PGRST_DB_URI = "postgres://authenticator:\${DB_PASSWORD}@db:5432/postgres";
        PGRST_DB_SCHEMAS = "public,storage,graphql_public";
        PGRST_DB_ANON_ROLE = "anon";
        PGRST_LOG_LEVEL = instanceCfg.logLevel;
        PGRST_JWT_SECRET = "\${JWT_SECRET}";
      };
    };

    realtimeService = {
      image = "supabase/realtime:v2.34.47";
      depends_on = ["db"];
      restart = "unless-stopped";
      environment = {
        PORT = "4000";
        DB_HOST = "db";
        DB_PORT = "5432";
        DB_USER = "supabase_realtime_admin";
        DB_PASSWORD = "\${DB_PASSWORD}";
        DB_NAME = "postgres";
        DB_AFTER_CONNECT_QUERY = "SET search_path TO _realtime";
        DB_ENC_KEY = "supabaserealtime";
        FLY_ALLOC_ID = "fly123";
        FLY_APP_NAME = "realtime";
        SECRET_KEY_BASE = "UpNVntn3cDxHJpq99YMc1T1AQgQpc8kfYTuRgBiYa15BLrx8etQoXz3gZv1/u2oq";
        JWT_SECRET = "\${JWT_SECRET}";
        RLIMIT_NOFILE = "1048576";
      };
      command = [
        "sh"
        "-c"
        "/app/bin/realtime eval Realtime.Release.migrate && /app/bin/realtime start"
      ];
    };

    storageService = {
      image = "supabase/storage-api:v1.23.0";
      depends_on = ["db" "rest"];
      restart = "unless-stopped";
      environment = {
        POSTGREST_URL = "http://rest:3000";
        DATABASE_URL = "postgres://supabase_storage_admin:\${DB_PASSWORD}@db:5432/postgres";
        PGOPTIONS = "-c search_path=storage,public";
        FILE_SIZE_LIMIT = "52428800";
        STORAGE_BACKEND = "file";
        FILE_STORAGE_BACKEND_PATH = "/var/lib/storage";
        TENANT_ID = "stub";
        REGION = "stub";
        GLOBAL_S3_BUCKET = instanceCfg.storage.bucket;
        SUPABASE_ANON_KEY = "\${SUPABASE_ANON_KEY}";
        SUPABASE_SERVICE_KEY = "\${SUPABASE_SERVICE_KEY}";
        PGRST_JWT_SECRET = "\${JWT_SECRET}";
      };
      volumes = ["./storage:/var/lib/storage"];
    };

    studioService = {
      image = "supabase/studio:2025.06.02-sha-8f2993d";
      restart = "unless-stopped";
      ports = ["${toString (port + 1)}:3000"];
      environment = {
        STUDIO_PG_META_URL = "http://meta:8080";
        DEFAULT_ORGANIZATION_NAME = instanceCfg.subdomain;
        DEFAULT_PROJECT_NAME = instanceCfg.subdomain;
        SUPABASE_URL = "http://kong:8000";
        SUPABASE_PUBLIC_URL = "https://${instanceCfg.subdomain}.${domain}";
        SUPABASE_ANON_KEY = "\${SUPABASE_ANON_KEY}";
        SUPABASE_SERVICE_KEY = "\${SUPABASE_SERVICE_KEY}";
      };
    };

    metaService = {
      image = "supabase/postgres-meta:v0.89.3";
      depends_on = ["db"];
      restart = "unless-stopped";
      environment = {
        PG_META_PORT = "8080";
        PG_META_DB_HOST = "db";
        PG_META_DB_PORT = "5432";
        PG_META_DB_NAME = "postgres";
        PG_META_DB_USER = "postgres";
        PG_META_DB_PASSWORD = "\${DB_PASSWORD}";
      };
    };

    imgproxyService = {
      image = "darthsim/imgproxy:v3.8.0";
      restart = "unless-stopped";
      environment = {
        IMGPROXY_BIND = "0.0.0.0:5001";
        IMGPROXY_LOCAL_FILESYSTEM_ROOT = "/";
        IMGPROXY_USE_ETAG = "true";
        IMGPROXY_ENABLE_WEBP_DETECTION = "true";
      };
      volumes = ["./storage:/var/lib/storage:ro"];
    };

    analyticsService = {
      image = "supabase/logflare:1.14.2";
      restart = "unless-stopped";
      depends_on = ["db"];
      environment = {
        LOGFLARE_NODE_HOST = "127.0.0.1";
        DB_USERNAME = "postgres";
        DB_PASSWORD = "\${DB_PASSWORD}";
        DB_DATABASE = "postgres";
        DB_HOSTNAME = "db";
        DB_PORT = "5432";
        LOGFLARE_API_KEY = "your-super-secret-and-long-logflare-key";
        LOGFLARE_SINGLE_TENANT = "true";
        LOGFLARE_SUPABASE_MODE = "true";
        LOGFLARE_MIN_CLUSTER_SIZE = "1";
      };
      ports = ["${toString (port + 2)}:4000"];
    };

    dbService = {
      image = "supabase/postgres:15.8.1.060";
      command = [
        "postgres"
        "-c"
        "config_file=/etc/postgresql/postgresql.conf"
        "-c"
        "log_min_messages=fatal"
      ];
      restart = "unless-stopped";
      ports = ["${toString (port + 3)}:5432"];
      environment = {
        POSTGRES_HOST = "/var/run/postgresql";
        PGPORT = "5432";
        POSTGRES_PORT = "5432";
        PGDATABASE = "postgres";
        POSTGRES_DB = "postgres";
        POSTGRES_USER = "postgres";
        POSTGRES_PASSWORD = "\${DB_PASSWORD}";
        JWT_EXP = "3600";
        JWT_SECRET = "\${JWT_SECRET}";
      };
      volumes = [
        "./db/data:/var/lib/postgresql/data"
        "./db/init:/docker-entrypoint-initdb.d"
      ];
    };

    # Filter services based on configuration (apply conditionals here)
    enabledServices =
      lib.filterAttrs (
        name: service:
          if name == "kong"
          then instanceCfg.services.restApi
          else if name == "auth"
          then instanceCfg.services.auth
          else if name == "rest"
          then instanceCfg.services.restApi
          else if name == "realtime"
          then instanceCfg.services.realtime
          else if name == "storage"
          then instanceCfg.services.storage
          else true # Enable db, studio, meta, imgproxy, analytics by default
      ) {
        db = dbService;
        kong = kongService;
        auth = authService;
        rest = restService;
        realtime = realtimeService;
        storage = storageService;
        studio = studioService;
        meta = metaService;
        imgproxy = imgproxyService;
        analytics = analyticsService;
      };

    # Compose configuration as Nix attribute set
    composeConfig = {
      version = "3.8";
      services = enabledServices;
      networks.default = {
        name = "supabase-${name}";
      };
    };
  in
    lib.generators.toYAML {} composeConfig;
in {
  # Generate systemd service for an instance
  generateService = name: instanceCfg: config: let
    dockerComposeContent = generateDockerCompose name instanceCfg config;
  in {
    description = "Supabase instance: ${name}";
    after = ["network.target" "postgresql.service" "podman.service"];
    wants = ["postgresql.service"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      Type = "simple";
      User = "root";
      Group = "root";
      WorkingDirectory = "/var/lib/supabase-${name}";
      StateDirectory = "supabase-${name}";
      StateDirectoryMode = "0755";

      # Load all secret files as environment variables
      EnvironmentFile = [
        config.age.secrets.${instanceCfg.jwtSecret}.path
        config.age.secrets.${instanceCfg.anonKey}.path
        config.age.secrets.${instanceCfg.serviceKey}.path
        config.age.secrets.${instanceCfg.dbPassword}.path
      ];

      # Use podman-compose to manage the Supabase stack
      ExecStartPre = [
        # Generate docker-compose file and copy configuration files
        "${pkgs.writeShellScript "generate-compose-${name}" ''
          # Create directory structure
          mkdir -p /var/lib/supabase-${name}/{storage,db/data,db/init}

          # Generate docker-compose.yml
          cat > /var/lib/supabase-${name}/docker-compose.yml << 'EOF'
          ${dockerComposeContent}
          EOF

          # Copy Kong configuration (remove directory if it exists, then copy file)
          rm -rf /var/lib/supabase-${name}/kong.yml
          cp ${kongConfig} /var/lib/supabase-${name}/kong.yml
          chmod 644 /var/lib/supabase-${name}/kong.yml

          # Set proper permissions for container storage
          chown -R root:root /var/lib/supabase-${name}
          chmod -R 755 /var/lib/supabase-${name}
          chmod 755 /var/lib/supabase-${name}/storage /var/lib/supabase-${name}/db/data
        ''}"
        # Pull images
        "${pkgs.writeShellScript "pull-images-${name}" ''
          export PATH=${lib.makeBinPath [pkgs.podman pkgs.podman-compose]}:$PATH
          export STORAGE_DRIVER=overlay
          ${pkgs.podman-compose}/bin/podman-compose -f /var/lib/supabase-${name}/docker-compose.yml pull
        ''}"
      ];

      ExecStart = "${pkgs.writeShellScript "start-supabase-${name}" ''
        export PATH=${lib.makeBinPath [pkgs.podman pkgs.podman-compose]}:$PATH
        # Ensure environment variables are available for docker-compose interpolation
        cd /var/lib/supabase-${name}
        ${pkgs.podman-compose}/bin/podman-compose -f docker-compose.yml up
      ''}";
      ExecStop = "${pkgs.writeShellScript "stop-supabase-${name}" ''
        export PATH=${lib.makeBinPath [pkgs.podman pkgs.podman-compose]}:$PATH
        cd /var/lib/supabase-${name}
        ${pkgs.podman-compose}/bin/podman-compose -f docker-compose.yml down
      ''}";

      Restart = "always";
      RestartSec = "10";

      # Security settings (relaxed for container management)
      NoNewPrivileges = false;
      ProtectSystem = false;
      ProtectHome = false;
      PrivateTmp = false;
      ReadWritePaths = ["/var/lib/supabase-${name}" "/var/lib/containers" "/run/user" "/tmp"];
    };
  };
}
