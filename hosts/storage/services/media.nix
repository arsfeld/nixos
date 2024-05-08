{config, ...}: let
  vars = config.vars;
in {
  services.bazarr = {
    enable = true;
    user = vars.user;
    group = vars.group;
  };

  services.lidarr = {
    enable = true;
    user = vars.user;
    group = vars.group;
  };

  services.radarr = {
    enable = true;
    user = vars.user;
    group = vars.group;
  };

  services.sonarr = {
    enable = true;
    user = vars.user;
    group = vars.group;
  };

  services.prowlarr = {
    enable = true;
  };

  services.jellyfin = {
    enable = true;
    user = vars.user;
    group = vars.group;
  };

  age.secrets."transmission-openvpn-pia".file = ../../../secrets/transmission-openvpn-pia.age;

  virtualisation.oci-containers.containers = {
    plex = {
      image = "lscr.io/linuxserver/plex";
      environment = {
        PUID = vars.puid;
        PGID = vars.pgid;
        TZ = vars.tz;
        VERSION = "latest";
      };
      environmentFiles = [
        "${vars.configDir}/plex/env"
      ];
      volumes = [
        "${vars.configDir}/plex:/config"
        "${vars.storageDir}/media:/data"
      ];
      extraOptions = [
        "--device"
        "/dev/dri:/dev/dri"
        "--network=host"
      ];
    };

    "transmission-openvpn" = {
      image = "haugene/transmission-openvpn";
      environment = {
        PUID = vars.puid;
        PGID = vars.pgid;
        TZ = vars.tz;

        LOCAL_NETWORK = "192.168.1.0/24,192.168.2.0/24,100.64.0.0/10";
        TRANSMISSION_WEB_UI = "flood-for-transmission";
        TRANSMISSION_RPC_AUTHENTICATION_REQUIRED = "true";
        TRANSMISSION_RPC_USERNAME = "admin";
        TRANSMISSION_RPC_PASSWORD = "{d8fdc58747d7f336a38e1676c9f5ce6b3daee67b3d6a62b1";
        TRANSMISSION_DOWNLOAD_DIR = "${vars.storageDir}/media/Downloads";
        TRANSMISSION_INCOMPLETE_DIR = "${vars.storageDir}/media/Downloads/incomplete";
        TRANSMISSION_SPEED_LIMIT_UP = "1000";
        TRANSMISSION_SPEED_LIMIT_UP_ENABLED = "true";
        WEBPROXY_ENABLED = "true";
        WEBPROXY_PORT = "8118";
        OVERRIDE_DNS_1 = "8.8.8.8";
      };
      environmentFiles = [
        config.age.secrets.transmission-openvpn-pia.path
      ];
      ports = ["9091:9091" "8118:8118"];
      volumes = [
        "${vars.configDir}/transmission-openvpn:/config"
        "${vars.dataDir}:${vars.dataDir}"
        "${vars.storageDir}:${vars.storageDir}"
      ];
      extraOptions = [
        "--cap-add"
        "NET_ADMIN"
        "--cap-add"
        "NET_RAW"
        "--sysctl"
        "net.ipv4.conf.all.src_valid_mark=1"
        "--sysctl"
        "net.ipv6.conf.all.disable_ipv6=0"
      ];
    };

    transmission-rss = {
      image = "haugene/transmission-rss";
      volumes = [
        "${vars.configDir}/transmission-rss/transmission-rss.conf:/etc/transmission-rss.conf"
        "${vars.configDir}/transmission-rss/seen:/etc/seen"
      ];
    };

    stash = {
      image = "stashapp/stash:latest";
      #ports = ["9999:9999"];
      volumes = [
        "${vars.configDir}/stash:/root/.stash"
        "${vars.storageDir}/media:/data"
      ];
      extraOptions = [
        "--device"
        "/dev/dri:/dev/dri"
        "--network=host"
      ];
    };

    jackett = {
      image = "ghcr.io/linuxserver/jackett";
      environment = {
        PUID = vars.puid;
        PGID = vars.pgid;
        TZ = vars.tz;
      };
      ports = ["9117:9117"];
      volumes = [
        "${vars.configDir}/jackett:/config"
        "${vars.dataDir}/files:/files"
        "${vars.storageDir}/media:/media"
      ];
    };

    overseerr = {
      image = "lscr.io/linuxserver/overseerr:latest";
      environment = {
        PUID = vars.puid;
        PGID = vars.pgid;
        TZ = vars.tz;
      };
      ports = ["5055:5055"];
      volumes = [
        "${vars.configDir}/overseerr:/config"
      ];
    };

    flaresolverr = {
      image = "ghcr.io/flaresolverr/flaresolverr:latest";
      ports = ["8191:8191"];
    };
  };
}
