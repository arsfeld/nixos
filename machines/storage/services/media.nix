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
        "${vars.dataDir}/media:/data"
      ];
      extraOptions = [
        "--device"
        "/dev/dri:/dev/dri"
        "--network=host"
      ];
    };

    xteve = {
      image = "dnsforge/xteve:latest";
      volumes = [
        "${vars.configDir}/xteve:/home/xteve/conf"
      ];
      ports = ["34400:34400"];
    };

    jf-vue = {
      image = "jellyfin/jellyfin-vue:unstable";
      environment = {
        DEFAULT_SERVERS = "https://jellyfin.${vars.domain}";
      };
      ports = ["3831:80"];
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
        TRANSMISSION_DOWNLOAD_DIR = "/media/Downloads";
        TRANSMISSION_INCOMPLETE_DIR = "/media/Downloads/incomplete";
        TRANSMISSION_SPEED_LIMIT_UP = "1000";
        TRANSMISSION_SPEED_LIMIT_UP_ENABLED = "true";
        WEBPROXY_ENABLED = "true";
        WEBPROXY_PORT = "8118";
      };
      environmentFiles = [
        config.age.secrets.transmission-openvpn-pia.path
      ];
      ports = ["9091:9091" "8118:8118"];
      volumes = [
        "${vars.configDir}/transmission-openvpn:/config"
        "${vars.dataDir}/media:/media"
        "${vars.dataDir}/files:/files"
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
        "${vars.dataDir}/media:/data"
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
        "${vars.dataDir}/media:/media"
      ];
    };

    sonarr = {
      image = "ghcr.io/linuxserver/sonarr";
      environment = {
        PUID = vars.puid;
        PGID = vars.pgid;
        TZ = vars.tz;
      };
      ports = ["8989:8989"];
      volumes = [
        "${vars.configDir}/sonarr:/config"
        "${vars.dataDir}/files:/files"
        "${vars.dataDir}/media:/media"
      ];
    };

    radarr = {
      image = "lscr.io/linuxserver/radarr:latest";
      environment = {
        PUID = vars.puid;
        PGID = vars.pgid;
        TZ = vars.tz;
      };
      ports = ["7878:7878"];
      volumes = [
        "${vars.configDir}/radarr:/config"
        "${vars.dataDir}/files:/files"
        "${vars.dataDir}/media:/media"
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

    prowlarr = {
      image = "ghcr.io/linuxserver/prowlarr:develop";
      environment = {
        PUID = vars.puid;
        PGID = vars.pgid;
        TZ = vars.tz;
      };
      ports = ["9696:9696"];
      volumes = [
        "${vars.configDir}/prowlarr:/config"
        "${vars.dataDir}/files:/files"
        "${vars.dataDir}/media:/media"
      ];
    };

    flaresolverr = {
      image = "ghcr.io/flaresolverr/flaresolverr:latest";
      ports = ["8191:8191"];
    };
  };
}
