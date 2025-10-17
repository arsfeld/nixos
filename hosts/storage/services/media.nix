{
  config,
  self,
  pkgs,
  lib,
  ...
}: let
  vars = config.media.config;
  services = config.media.gateway.services;

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

  services.komga = {
    enable = true;
    user = vars.user;
    group = vars.group;
    settings.server.port = services.komga.port;
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
    port = services.headphones.port;
  };

  services.bitmagnet = {
    enable = false;
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
  age.secrets."airvpn-wireguard".file = "${self}/secrets/airvpn-wireguard.age";

  # Required sysctl for VPN containers (qflood, transmission-openvpn)
  boot.kernel.sysctl = {
    # Enable reverse path filtering with fwmark support
    # Required for WireGuard policy routing - allows marked packets to use VPN routing tables
    "net.ipv4.conf.all.src_valid_mark" = 1;

    # Keep IPv6 enabled (0 = enabled, 1 = disabled)
    # AirVPN config includes IPv6 addresses
    "net.ipv6.conf.all.disable_ipv6" = 0;
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

  # Setup wireguard config for qflood
  systemd.tmpfiles.rules = lib.mkAfter [
    "d ${vars.configDir}/qflood/wireguard 0750 ${toString vars.puid} ${toString vars.pgid}"
  ];

  # Copy AirVPN WireGuard config before starting container
  systemd.services.podman-qflood.preStart = lib.mkAfter ''
    ${pkgs.coreutils}/bin/cp -f ${config.age.secrets.airvpn-wireguard.path} ${vars.configDir}/qflood/wireguard/wg0.conf
    ${pkgs.coreutils}/bin/chown ${toString vars.puid}:${toString vars.pgid} ${vars.configDir}/qflood/wireguard/wg0.conf
    ${pkgs.coreutils}/bin/chmod 600 ${vars.configDir}/qflood/wireguard/wg0.conf
  '';

  virtualisation.oci-containers.containers = {
    # qbittorrent = {
    #   image = "j4ym0/pia-qbittorrent";
    #   environment = {
    #     UID = toString vars.puid;
    #     GID = toString vars.pgid;
    #     TZ = vars.tz;

    #     PORT_FORWARDING = "true";
    #   };
    #   environmentFiles = [
    #     config.age.secrets.qbittorrent-pia.path
    #   ];
    #   ports = ["8999:8888"];
    #   volumes = [
    #     "${vars.configDir}/qbittorrent-pia:/config"
    #     "${vars.dataDir}:${vars.dataDir}"
    #     "${vars.storageDir}:${vars.storageDir}"
    #     "${vars.storageDir}/media:/media"
    #   ];
    #   extraOptions = [
    #     "--privileged"
    #   ];
    # };

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
        "${vars.storageDir}/files:/files"
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

    # threadfin = {
    #   image = "fyb3roptik/threadfin";
    #   environment = {
    #     TZ = "America/Toronto";
    #   };
    #   ports = ["34400:34400"];
    #   volumes = [
    #     "${vars.configDir}/threadfin:/home/threadfin/conf"
    #   ];
    # };
  };
}
