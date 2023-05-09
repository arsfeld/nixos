{
  lib,
  config,
  pkgs,
  ...
}: let
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

    jf-vue = {
      image = "jellyfin/jellyfin-vue:unstable";
      environment = {
        DEFAULT_SERVERS = "https://jellyfin.${vars.domain}";
      };
      ports = ["3831:80"];
    };

    qflood = {
      image = "cr.hotio.dev/hotio/qflood";
      environment = {
        PUID = vars.puid;
        PGID = vars.pgid;
        TZ = vars.tz;
        FLOOD_AUTH = "false";
        VPN_LAN_NETWORK = "192.168.31.0/24,100.64.0.0/10";
        VPN_ENABLED = "true";
        VPN_IP_CHECK_DELAY = "15";
      };
      ports = ["8080:8080/tcp" "3000:3000"];
      volumes = [
        "${vars.configDir}/qflood:/config"
        "${vars.dataDir}/media:/media"
        "${vars.dataDir}/files:/files"
      ];
      extraOptions = [
        "--cap-add"
        "NET_ADMIN"
        "--sysctl"
        "net.ipv4.conf.all.src_valid_mark=1"
        "--sysctl"
        "net.ipv6.conf.all.disable_ipv6=1"
      ];
    };

    # gluetun = {
    #   image = "ghcr.io/qdm12/gluetun";
    #   environment = {
    #     VPN_SERVICE_PROVIDER = "MULLVAD";
    #     VPN_TYPE = "openvpn";
    #     OPENVPN_USER = "4493235546215778";
    #     OPENVPN_PASSWORD = "m";
    #   };
    #   ports = ["8080:8080"];
    #   volumes = [
    #     "/dev/net/tun:/dev/net/tun"
    #     "${vars.configDir}/gluetun:/gluetun"
    #   ];
    #   extraOptions = [
    #     "--cap-add"
    #     "NET_ADMIN"
    #     "--dns"
    #     "8.8.8.8"
    #     "--dns"
    #     "8.8.4.4"
    #   ];
    # };

    # qbittorrent = {
    #   image = "lscr.io/linuxserver/qbittorrent:latest";
    #   environment = {
    #     PUID = vars.puid;
    #     PGID = vars.pgid;
    #     TZ = vars.tz;
    #     WEBUI_PORT = "8080";
    #   };
    #   volumes = [
    #     "${vars.configDir}/qbittorrent:/config"
    #     "${vars.dataDir}/media:/media"
    #     "${vars.dataDir}/files:/files"
    #   ];
    #   extraOptions = [
    #     "--network"
    #     "container:gluetun"
    #   ];
    # };

    stash = {
      image = "stashapp/stash:latest";
      ports = ["9999:9999"];
      volumes = [
        "${vars.configDir}/stash:/root/.stash"
        "${vars.dataDir}/media:/data"
      ];
    };

    nzbget = {
      image = "ghcr.io/linuxserver/nzbget";
      environment = {
        PUID = vars.puid;
        PGID = vars.pgid;
        TZ = vars.tz;
      };
      ports = ["6789:6789"];
      volumes = [
        "${vars.configDir}/nzbget:/config"
        "${vars.dataDir}/files:/files"
        "${vars.dataDir}/media:/media"
      ];
    };

    sabnzbd = {
      image = "ghcr.io/linuxserver/sabnzbd";
      environment = {
        PUID = vars.puid;
        PGID = vars.pgid;
        TZ = vars.tz;
      };
      ports = ["8880:8080"];
      volumes = [
        "${vars.configDir}/sabnzbd:/config"
        "${vars.dataDir}/files:/files"
        "${vars.dataDir}/media:/media"
      ];
    };

    nzbhydra2 = {
      image = "ghcr.io/linuxserver/nzbhydra2";
      environment = {
        PUID = vars.puid;
        PGID = vars.pgid;
        TZ = vars.tz;
      };
      ports = ["5076:5076"];
      volumes = [
        "${vars.configDir}/nzbhydra2:/config"
        "${vars.dataDir}/files:/files"
        "${vars.dataDir}/media:/media"
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
      image = "ghcr.io/linuxserver/radarr";
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

    whisparr = {
      image = "cr.hotio.dev/hotio/whisparr";
      environment = {
        PUID = vars.puid;
        PGID = vars.pgid;
        TZ = vars.tz;
      };
      ports = ["6969:6969"];
      volumes = [
        "${vars.configDir}/whisparr:/config"
        "${vars.dataDir}/media:/media"
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
