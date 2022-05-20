{
  lib,
  config,
  pkgs,
  nixpkgs,
  modulesPath,
  ...
}:
with lib; let
  configDir = "/var/lib";
  puid = "5000";
  pgid = "5000";
  tz = "America/Toronto";
  domain = "arsfeld.dev";
in {
  virtualisation.oci-containers.containers = {
    watchtower = {
      image = "containrrr/watchtower";
      volumes = [
        "/var/run/docker.sock:/var/run/docker.sock"
      ];
    };

    vaultwarden = {
      image = "vaultwarden/server";
      user = "${puid}:${pgid}";
      environment = {
        TZ = tz;
      };
      ports = ["8888:80"];
      volumes = [
        "${configDir}/vaultwarden:/data"
      ];
    };

    ghost = {
      image = "ghost";
      user = "${puid}:${pgid}";
      environment = {
        url = "https://blog.${domain}";
      };
      ports = ["2368:2368"];
      volumes = [
        "${configDir}/ghost:/var/lib/ghost/content"
      ];
    };

    yarr = {
      image = "arsfeld/yarr:latest";
      user = "${puid}:${pgid}";
      ports = ["7070:7070"];
      volumes = [
        "${configDir}/yarr:/data"
      ];
    };
  };
}
