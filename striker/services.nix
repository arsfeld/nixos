{ lib, config, pkgs, nixpkgs, modulesPath, ... }:

with lib;

let
  configDir = "/var/data";
  dataDir = "/mnt/data";
  puid = "5000";
  pgid = "5000";
  tz = "America/Toronto";
in {
  services.netdata.enable = true;

  services.restic.server = {
    enable = true;
    dataDir = "/data/files/Backups/restic";
  };

  virtualisation.oci-containers.containers = {
    plex = {
      image = "lscr.io/linuxserver/plex";
      environment = {
        PUID = puid;
        PGID = pgid;
        TZ = tz;
        VERSION = "latest";
      };
      environmentFiles = [
        "${configDir}/plex/env"
      ];
      volumes = [
        "${configDir}/plex:/config"
        "${dataDir}/media:/data"
      ];
      extraOptions = [ 
        "--device" "/dev/dri:/dev/dri"
        "--network=host" 
      ];
    };

    gluetun = {
      image = "qmcgaw/gluetun";
      environment = {
        # See https://github.com/qdm12/gluetun/wiki
        DOT = "off";
        VPNSP = "mullvad";
        VPN_TYPE = "wireguard";
      };
      environmentFiles = [
        "${configDir}/gluetun/env"
      ];
      volumes = [
        "${configDir}/gluetun:/gluetun"
      ];
      ports = [ "8080:8080/tcp" ];
      extraOptions = [ 
        "--cap-add=NET_ADMIN" 
      ];
    };
  };
}
