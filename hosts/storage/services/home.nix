{config, ...}: let
  vars = config.vars;
in {
  virtualisation.oci-containers.containers = {
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
