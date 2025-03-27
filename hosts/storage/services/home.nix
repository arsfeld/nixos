{
  self,
  config,
  pkgs,
  ...
}: let
  vars = config.media.config;
  cacheDir = "/var/cache/finance-tracker";
in {
  age.secrets."finance-tracker-env" = {
    file = "${self}/secrets/finance-tracker-env.age";
  };

  # Enable and configure Kestra
  services.kestra = {
    enable = true;

    # Database configuration
    database = {
      createLocally = true; # Create PostgreSQL database on this host
      host = "localhost"; # Use localhost since we're creating the database locally
      name = "kestra"; # Database name
      username = "kestra"; # Database username
      password = "kestra"; # Database password - consider using a more secure password
    };

    # Kestra configuration (optional - these are the defaults)
    port = 8080;
    adminPort = 8081;
    basicAuth = false;
    basicAuthUsername = "admin@localhost.dev";
    basicAuthPassword = "kestra";
  };

  systemd.services.finance-tracker = {
    description = "Finance Tracker Service";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    environment = {
      XDG_CACHE_HOME = cacheDir;
    };

    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStartPre = [
        (pkgs.writeShellScript "finance-tracker-pre.sh" ''
          ${pkgs.coreutils}/bin/mkdir -p ${cacheDir}/bin &&
          ${pkgs.curl}/bin/curl -L -z "${cacheDir}/bin/finance-tracker" \
            -o "${cacheDir}/bin/finance-tracker" \
            "https://getbin.io/arsfeld/finance-tracker?os=linux" &&
          ${pkgs.coreutils}/bin/chmod +x "${cacheDir}/bin/finance-tracker"
        '')
      ];
      ExecStart = "${cacheDir}/bin/finance-tracker";
      EnvironmentFile = "${config.age.secrets."finance-tracker-env".path}";
    };
  };

  systemd.timers.finance-tracker = {
    wantedBy = ["timers.target"];
    partOf = ["finance-tracker.service"];
    timerConfig = {
      OnCalendar = "*-*-* 17:00:00";
      Persistent = true;
    };
  };

  virtualisation.oci-containers.containers = {
    homeassistant = {
      volumes = ["/var/lib/home-assistant:/config"];
      environment.TZ = "America/Toronto";
      image = "ghcr.io/home-assistant/home-assistant:stable";
      extraOptions = [
        "--network=host"
        "--privileged"
        "--label"
        "io.containers.autoupdate=image"
      ];
    };

    grocy = {
      image = "lscr.io/linuxserver/grocy:latest";
      environment = {
        PUID = toString vars.puid;
        PGID = toString vars.pgid;
        TZ = vars.tz;
      };
      volumes = [
        "${vars.configDir}/grocy:/config"
      ];
      ports = ["9283:80"];
    };

    stirling = {
      image = "frooodle/s-pdf:latest";
      volumes = [
        "${vars.configDir}/stirling:/configs"
      ];
      ports = ["9284:8080"];
    };
  };
}
