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

  services.code-server = {
    enable = true;
    user = "arosenfeld";
    group = "users";
    host = "0.0.0.0";
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

    syncthing = {
      image = "ghcr.io/linuxserver/syncthing";
      environment = {
        PUID = puid;
        PGID = pgid;
        TZ = tz;
      };
      ports = [ "8384:8384" "22000:22000" "21027:21027/udp" ];
      volumes = [
        "${configDir}/syncthing:/config"
        "${dataDir}/files:/data"
        "${dataDir}/files:/files"
        "${dataDir}/media:/media"
      ];
    };

    stash = {
      image = "stashapp/stash:latest";
      ports = [ "9999:9999" ];
      volumes = [
        "${configDir}/stash:/root/.stash"
        "${dataDir}/media:/data"
      ];
    };

    filestash = {
      image = "machines/filestash";
      ports = [ "8334:8334" ];
      volumes = [
        "${configDir}/filestash:/app/data/state"
        "${dataDir}/media:/mnt/data/media"
        "${dataDir}/files:/mnt/data/files"
      ];
    };

    nzbget = {
      image = "ghcr.io/linuxserver/nzbget";
      environment = {
        PUID = puid;
        PGID = pgid;
        TZ = tz;
      };
      ports = [ "6789:6789" ];
      volumes = [
        "${configDir}/nzbget:/config"
        "${dataDir}/files:/files"
        "${dataDir}/media:/media"
      ];
    };

    sabnzbd = {
      image = "ghcr.io/linuxserver/sabnzbd";
      environment = {
        PUID = puid;
        PGID = pgid;
        TZ = tz;
      };
      ports = [ "8880:8080" ];
      volumes = [
        "${configDir}/sabnzbd:/config"
        "${dataDir}/files:/files"
        "${dataDir}/media:/media"
      ];
    };

    nzbhydra2 = {
      image = "ghcr.io/linuxserver/nzbhydra2";
      environment = {
        PUID = puid;
        PGID = pgid;
        TZ = tz;
      };
      ports = [ "5076:5076" ];
      volumes = [
        "${configDir}/nzbhydra2:/config"
        "${dataDir}/files:/files"
        "${dataDir}/media:/media"
      ];
    };

    jackett = {
      image = "ghcr.io/linuxserver/jackett";
      environment = {
        PUID = puid;
        PGID = pgid;
        TZ = tz;
      };
      ports = [ "9117:9117" ];
      volumes = [
        "${configDir}/jackett:/config"
        "${dataDir}/files:/files"
        "${dataDir}/media:/media"
      ];
    };

    sonarr = {
      image = "ghcr.io/linuxserver/sonarr";
      environment = {
        PUID = puid;
        PGID = pgid;
        TZ = tz;
      };
      ports = [ "8989:8989" ];
      volumes = [
        "${configDir}/sonarr:/config"
        "${dataDir}/files:/files"
        "${dataDir}/media:/media"
      ];
    };

    radarr = {
      image = "ghcr.io/linuxserver/radarr";
      environment = {
        PUID = puid;
        PGID = pgid;
        TZ = tz;
      };
      ports = [ "7878:7878" ];
      volumes = [
        "${configDir}/radarr:/config"
        "${dataDir}/files:/files"
        "${dataDir}/media:/media"
      ];
    };

    prowlarr = {
      image = "ghcr.io/linuxserver/prowlarr:develop";
      environment = {
        PUID = puid;
        PGID = pgid;
        TZ = tz;
      };
      ports = [ "9696:9696" ];
      volumes = [
        "${configDir}/prowlarr:/config"
        "${dataDir}/files:/files"
        "${dataDir}/media:/media"
      ];
    };
  };
}
