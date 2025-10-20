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

  # Required sysctl for VPN containers (qbittorrent, transmission-openvpn)
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

  # Setup wireguard config for qbittorrent
  systemd.tmpfiles.rules = lib.mkAfter [
    "d ${vars.configDir}/qbittorrent/wireguard 0750 ${toString vars.puid} ${toString vars.pgid}"
  ];

  # Copy AirVPN WireGuard config before starting qbittorrent container
  systemd.services.podman-qbittorrent.serviceConfig.ExecStartPre = lib.mkAfter [
    "${pkgs.writeShellScript "copy-airvpn-config-qbittorrent" ''
      ${pkgs.coreutils}/bin/rm -f ${vars.configDir}/qbittorrent/wireguard/wg0.conf
      ${pkgs.coreutils}/bin/cp ${config.age.secrets.airvpn-wireguard.path} ${vars.configDir}/qbittorrent/wireguard/wg0.conf
      ${pkgs.coreutils}/bin/chown ${toString vars.puid}:${toString vars.pgid} ${vars.configDir}/qbittorrent/wireguard/wg0.conf
      ${pkgs.coreutils}/bin/chmod 600 ${vars.configDir}/qbittorrent/wireguard/wg0.conf
    ''}"
  ];

  virtualisation.oci-containers.containers = {
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
