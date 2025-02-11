{
  self,
  config,
  ...
}: let
  vars = config.vars;
in {
  age.secrets."finance-tracker-env" = {
    file = "${self}/secrets/finance-tracker-env.age";
  };

  virtualisation.oci-containers.containers = {
    finance-tracker = {
      image = "ghcr.io/arsfeld/finance-tracker:latest";
      volumes = [
        "${vars.configDir}/finance-tracker:/app/data"
      ];
      ports = ["5150:5150"];
      cmd = ["start" "--server-and-worker"];
      environmentFiles = [
        config.age.secrets."finance-tracker-env".path
      ];
    };

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
