{
  config,
  self,
  pkgs,
  ...
}: let
  vars = config.vars;

  plex-trakt-sync = {interactive ? false}: ''    ${pkgs.docker}/bin/docker run ${
      if interactive
      then "-it"
      else ""
    } --rm \
            -v ${vars.configDir}/plex-track-sync:/app/config \
            ghcr.io/taxel/plextraktsync'';
in {
  services.bazarr = {
    enable = false;
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

  services.sabnzbd = {
    enable = false;
    user = vars.user;
    group = vars.group;
  };

  services.prowlarr.enable = true;
  services.nzbhydra2.enable = true;

  services.jellyfin = {
    enable = true;
    user = vars.user;
    group = vars.group;
  };

  services.tautulli = {
    enable = true;
    user = vars.user;
    group = vars.group;
  };

  services.headphones = {
    enable = true;
    user = vars.user;
    group = vars.group;
    host = "0.0.0.0";
    port = 8787;
  };

  services.bitmagnet = {
    enable = true;
  };

  age.secrets."bitmagnet-env".file = "${self}/secrets/bitmagnet-env.age";
  systemd.services.bitmagnet.serviceConfig.EnvironmentFile = config.age.secrets.bitmagnet-env.path;

  services.resilio = {
    enable = true;
    enableWebUI = true;
    httpListenAddr = "0.0.0.0";
  };

  users.users.rslsync.extraGroups = ["nextcloud" "media"];

  age.secrets."transmission-openvpn-pia".file = "${self}/secrets/transmission-openvpn-pia.age";
  age.secrets."qbittorrent-pia".file = "${self}/secrets/qbittorrent-pia.age";

  services.plex = {
    enable = true;
  };

  environment.systemPackages = [
    (pkgs.writeShellScriptBin "plex-trakt-sync" "${(plex-trakt-sync {interactive = true;})} \"$@\"")
  ];

  systemd.timers.plex-trakt-sync = {
    wantedBy = ["timers.target"];
    partOf = ["simple-timer.service"];
    timerConfig.OnCalendar = "weekly";
  };
  systemd.services.plex-trakt-sync = {
    serviceConfig.Type = "oneshot";
    script = "${(plex-trakt-sync {})} sync";
  };

  virtualisation.oci-containers.containers = {
    qbittorrent = {
      image = "j4ym0/pia-qbittorrent";
      environment = {
        UID = vars.puid;
        GID = vars.pgid;
        TZ = vars.tz;

        PORT_FORWARDING = "true";
      };
      environmentFiles = [
        config.age.secrets.qbittorrent-pia.path
      ];
      ports = ["8999:8888"];
      volumes = [
        "${vars.configDir}/qbittorrent-pia:/config"
        "${vars.dataDir}:${vars.dataDir}"
        "${vars.storageDir}:${vars.storageDir}"
      ];
      extraOptions = [
        "--cap-add"
        "NET_ADMIN"
        "--cap-add"
        "NET_RAW"
        "--device"
        "/dev/net/tun"
        "--sysctl"
        "net.ipv4.conf.all.src_valid_mark=1"
        "--sysctl"
        "net.ipv6.conf.all.disable_ipv6=0"
      ];
    };

    transmission-openvpn = {
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
        "--device"
        "/dev/net/tun"
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

    pinchflat = {
      image = "ghcr.io/kieraneglin/pinchflat:latest";
      environment = {
        TZ = "America/New_York";
      };
      ports = ["8945:8945"];
      volumes = [
        "${vars.configDir}/pinchflat:/config"
        "${vars.storageDir}/media/Pinchflat:/downloads"
      ];
    };

    fileflows = {
      image = "revenz/fileflows";
      ports = ["19200:5000"];
      environment = {
        TZ = "America/New_York";
        PUID = vars.puid;
        PGID = vars.pgid;
      };
      extraOptions = [
        "--device"
        "/dev/dri:/dev/dri"
      ];
      volumes = [
        "${vars.storageDir}/media:${vars.storageDir}/media"
        "${vars.configDir}/fileflows:/app/Data"
        "${vars.configDir}/fileflows/temp:/temp"
      ];
    };

    threadfin = {
      image = "fyb3roptik/threadfin";
      environment = {
        TZ = "America/Toronto";
      };
      ports = ["34400:34400"];
      volumes = [
        "${vars.configDir}/threadfin:/home/threadfin/conf"
      ];
    };
  };
}
