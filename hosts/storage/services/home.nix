{
  self,
  config,
  pkgs,
  ...
}: let
  vars = config.vars;
in {
  age.secrets."finance-tracker-env" = {
    file = "${self}/secrets/finance-tracker-env.age";
  };

  systemd.services.finance-tracker = {
    serviceConfig = {
      ExecStartPre = "${pkgs.docker}/bin/docker pull ghcr.io/arsfeld/finance-tracker:latest";
      ExecStart = ''${pkgs.docker}/bin/docker run \
        --env-file ${config.age.secrets."finance-tracker-env".path} \
        --rm ghcr.io/arsfeld/finance-tracker:latest'';
    };
  };

  systemd.timers.finance-tracker = {
    wantedBy = ["timers.target"];
    partOf = ["finance-tracker.service"];
    timerConfig = {
      OnCalendar = "Tue,Sun *-*-* 01,17:00:00";
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
        PUID = vars.puid;
        PGID = vars.pgid;
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
