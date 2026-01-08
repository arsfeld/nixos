{
  self,
  config,
  pkgs,
  ...
}: let
  vars = config.media.config;
  cacheDir = "/var/cache/finance-tracker";
  financeTrackerScript = pkgs.writeShellApplication {
    name = "finance-tracker";
    runtimeInputs = [pkgs.podman];
    text = ''
      exec podman run \
        --rm \
        --pull newer \
        --volume "${cacheDir}:${cacheDir}" \
        --volume "/etc/finance-tracker/filter-config.yaml:/app/filter-config.yaml:ro" \
        --env XDG_CACHE_HOME="${cacheDir}" \
        --env-file "${config.age.secrets."finance-tracker-env".path}" \
        ghcr.io/arsfeld/finance-tracker:latest ./finance-tracker "$@"
    '';
  };
in {
  age.secrets."finance-tracker-env" = {
    file = "${self}/secrets/finance-tracker-env.age";
  };

  # Deploy filter configuration to /etc
  environment.etc."finance-tracker/filter-config.yaml" = {
    text = builtins.readFile ../files/finance-tracker-filter.yaml;
    mode = "0444"; # read-only
  };

  # Create the finance-tracker script
  environment.systemPackages = [
    financeTrackerScript
  ];

  # Systemd service and timer for finance-tracker
  systemd.services.finance-tracker = {
    description = "Finance Tracker Service";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${financeTrackerScript}/bin/finance-tracker";
    };
  };

  systemd.timers.finance-tracker = {
    description = "Finance Tracker Timer";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "*-*-1/2 17:00:00";
      Persistent = true; # Run if missed
      RandomizedDelaySec = "1h"; # Random delay up to 1 hour
    };
  };

  # Enable and configure Kestra
  services.kestra = {
    enable = false;

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

  virtualisation.oci-containers.containers = {
    audiobookshelf = {
      image = "ghcr.io/advplyr/audiobookshelf:latest";
      environment = {
        PUID = toString vars.puid;
        PGID = toString vars.pgid;
        TZ = vars.tz;
      };
      volumes = [
        "${vars.configDir}/audiobookshelf/config:/config"
        "${vars.configDir}/audiobookshelf/metadata:/metadata"
        "${vars.dataDir}/media/audiobooks:/audiobooks"
        "${vars.dataDir}/media/podcasts:/podcasts"
      ];
      ports = ["13378:80"];
      extraOptions = [
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
