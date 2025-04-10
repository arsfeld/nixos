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
        --env XDG_CACHE_HOME="${cacheDir}" \
        --env-file "${config.age.secrets."finance-tracker-env".path}" \
        ghcr.io/arsfeld/finance-tracker:latest "$@"
    '';
  };
in {
  age.secrets."finance-tracker-env" = {
    file = "${self}/secrets/finance-tracker-env.age";
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
