{
  config,
  self,
  pkgs,
  lib,
  ...
}: let
  vars = config.mediaConfig;
  ports = config.mediaServices.ports;

  plex-trakt-sync = {interactive ? false}: ''    ${pkgs.podman}/bin/podman run ${
      if interactive
      then "-it"
      else ""
    } --rm \
                -v ${vars.configDir}/plex-track-sync:/app/config \
                ghcr.io/taxel/plextraktsync'';
in {
  services.lidarr = {
    enable = true;
    user = vars.user;
    group = vars.group;
  };

  services.sabnzbd = {
    enable = false;
    user = vars.user;
    group = vars.group;
  };

  services.komga = {
    enable = true;
    user = vars.user;
    group = vars.group;
    settings.server.port = ports.komga;
  };

  services.prowlarr = {
    enable = true;
  };

  services.nzbhydra2 = {
    enable = true;
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
    port = ports.headphones;
  };

  services.bitmagnet = {
    enable = false;
  };

  services.mediaContainers = {
    overseerr = {
      enable = true;
      listenPort = 5055;
      exposePort = ports.overseerr;
    };

    jackett = {
      enable = true;
      listenPort = 9117;
      exposePort = ports.jackett;
    };

    bazarr = {
      enable = true;
      listenPort = 6767;
      exposePort = ports.bazarr;
      mediaVolumes = true;
    };

    radarr = {
      enable = true;
      listenPort = 7878;
      exposePort = ports.radarr;
      mediaVolumes = true;
    };

    sonarr = {
      enable = true;
      listenPort = 8989;
      exposePort = ports.sonarr;
      mediaVolumes = true;
    };

    autobrr = {
      enable = true;
      imageName = "ghcr.io/autobrr/autobrr:latest";
      listenPort = 7474;
      exposePort = ports.autobrr;
    };

    pinchflat = {
      enable = true;
      imageName = "ghcr.io/kieraneglin/pinchflat:latest";
      listenPort = 8945;
      exposePort = ports.pinchflat;
      volumes = [
        "${vars.storageDir}/media/Pinchflat:/downloads"
      ];
    };

    plex = {
      enable = true;
      extraEnv = {
        VERSION = "latest";
      };
      mediaVolumes = true;
      extraOptions = [
        "--network=host"
        "--device=/dev/dri:/dev/dri"
      ];
    };
  };

  #age.secrets."bitmagnet-env".file = "${self}/secrets/bitmagnet-env.age";
  #systemd.services.bitmagnet.serviceConfig.EnvironmentFile = config.age.secrets.bitmagnet-env.path;

  services.resilio = {
    enable = true;
    enableWebUI = true;
    httpListenAddr = "0.0.0.0";
  };

  users.users.rslsync.extraGroups = ["nextcloud" "media"];

  age.secrets."transmission-openvpn-pia".file = "${self}/secrets/transmission-openvpn-pia.age";
  age.secrets."qbittorrent-pia".file = "${self}/secrets/qbittorrent-pia.age";

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
        UID = toString vars.puid;
        GID = toString vars.pgid;
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
        "${vars.storageDir}/media:/media"
      ];
      extraOptions = [
        "--privileged"
      ];
    };

    transmission-openvpn = {
      image = "haugene/transmission-openvpn";
      environment = {
        PUID = toString vars.puid;
        PGID = toString vars.pgid;
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
        "${vars.storageDir}/media:/media"
      ];
      extraOptions = [
        "--privileged"
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

    flaresolverr = {
      image = "ghcr.io/flaresolverr/flaresolverr:latest";
      ports = ["8191:8191"];
    };

    fileflows = {
      image = "revenz/fileflows";
      ports = ["19200:5000"];
      environment = {
        TZ = "America/New_York";
        PUID = toString vars.puid;
        PGID = toString vars.pgid;
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
