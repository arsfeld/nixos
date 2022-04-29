{
  lib,
  config,
  pkgs,
  nixpkgs,
  modulesPath,
  ...
}:
with lib; let
  configDir = "/var/data";
  dataDir = "/mnt/data";
  puid = "5000";
  pgid = "5000";
  tz = "America/Toronto";
  email = "arsfeld@gmail.com";
  domain = "striker.arsfeld.net";
in {
  services.netdata.enable = true;

  services.restic.server = {
    enable = false;
    dataDir = "/mnt/data/files/Backups/restic";
  };

  security.acme = {
    acceptTerms = true;
    certs = {
      "${domain}" = {
        #webroot = "/var/lib/acme/acme-challenge/";
        email = email;
        dnsProvider = "cloudflare";
        credentialsFile = "/var/lib/secrets/cloudflare";
        #extraDomainNames = [ "www.example.com" "foo.example.com" ];
      };
    };
  };

  users.users.caddy.extraGroups = ["acme"];

  services.home-assistant = {
    enable = true;
    config = {
      # https://www.home-assistant.io/integrations/default_config/
      default_config = {};
      # https://www.home-assistant.io/integrations/esphome/
      esphome = {};
      # https://www.home-assistant.io/integrations/met/
      met = {};
    };
  };

  services.caddy = {
    enable = true;
    email = email;
    virtualHosts = {
      "${domain}" = {
        useACMEHost = domain;
        serverAliases = ["striker"];
        extraConfig = ''
          root * /mnt/data
          file_server browse

          handle_path /stash/* {
            reverse_proxy http://localhost:9999
          }
        '';
      };
    };
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
        "--device"
        "/dev/dri:/dev/dri"
        "--network=host"
      ];
    };

    gluetun = {
      image = "qmcgaw/gluetun";
      environmentFiles = [
        "${configDir}/gluetun/env"
      ];
      volumes = [
        "${configDir}/gluetun:/gluetun"
      ];
      ports = ["8080:8080/tcp"];
      extraOptions = [
        "--cap-add=NET_ADMIN"
      ];
    };

    qbittorrent = {
      image = "ghcr.io/linuxserver/qbittorrent";
      environment = {
        PUID = puid;
        PGID = pgid;
        TZ = tz;
      };
      volumes = [
        "${configDir}/qbittorrent:/config"
        "${dataDir}/media:/media"
        "${dataDir}/files:/files"
      ];
      extraOptions = [
        "--network=container:gluetun"
      ];
    };

    # homeassistant = {
    #   volumes = [ "home-assistant:/config" ];
    #   environment.TZ = "America/Toronto";
    #   image = "ghcr.io/home-assistant/home-assistant:stable";
    #   extraOptions = [
    #     "--network=host"
    #   ];
    # };
  };
}
