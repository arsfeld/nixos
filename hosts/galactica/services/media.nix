{
  config,
  self,
  pkgs,
  lib,
  ...
}: let
  vars = config.media.config;
  nameToPort = import "${self}/common/nameToPort.nix";
  komgaPort = nameToPort "komga";
  headphonesPort = 8787;

  plex-trakt-sync = {interactive ? false}: ''    ${pkgs.podman}/bin/podman run ${
      if interactive
      then "-it"
      else ""
    } --rm \
                -v ${vars.configDir}/plex-track-sync:/app/config \
                ghcr.io/taxel/plextraktsync'';
in {
  media.services.komga = {port = komgaPort;};
  media.services.lidarr = {port = 8686;};
  media.services.tautulli = {port = 8181;};
  media.services.headphones = {port = headphonesPort;};
  media.services.resilio = {port = 9000;};

  media.services.fileflows = {
    port = 5000;
    image = "revenz/fileflows";
    container = {
      exposePort = 19200;
      configDir = "/app/Data";
      devices = ["/dev/dri:/dev/dri"];
      environment = {
        TZ = "America/New_York";
      };
      volumes = [
        "${vars.storageDir}/media:${vars.storageDir}/media"
        "${vars.configDir}/fileflows/temp:/temp"
      ];
    };
  };

  services.lidarr = {
    enable = true;
    user = vars.user;
    group = vars.group;
  };

  services.komga = {
    enable = true;
    user = vars.user;
    group = vars.group;
    settings.server.port = komgaPort;
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
    port = headphonesPort;
  };

  services.resilio = {
    enable = true;
    enableWebUI = true;
    httpListenAddr = "0.0.0.0";
  };

  users.users.rslsync.extraGroups = ["nextcloud" "media"];

  sops.secrets."transmission-openvpn-pia" = {};
  sops.secrets."qbittorrent-pia" = {};
  sops.secrets."airvpn-wireguard" = {};
  sops.secrets."transmission-openvpn-airvpn" = {};

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
  # DISABLED: qbittorrent container replaced with native service
  # systemd.tmpfiles.rules = lib.mkAfter [
  #   "d ${vars.configDir}/qbittorrent/wireguard 0750 ${toString vars.puid} ${toString vars.pgid}"
  #   "d ${vars.configDir}/transmission-openvpn/openvpn 0750 ${toString vars.puid} ${toString vars.pgid}"
  # ];

  # Copy AirVPN WireGuard config before starting qbittorrent container
  # DISABLED: qbittorrent container replaced with native service
  # systemd.services.podman-qbittorrent.serviceConfig.ExecStartPre = lib.mkAfter [
  #   "${pkgs.writeShellScript "copy-airvpn-config-qbittorrent" ''
  #     ${pkgs.coreutils}/bin/rm -f ${vars.configDir}/qbittorrent/wireguard/wg0.conf
  #     ${pkgs.coreutils}/bin/cp ${config.sops.secrets.airvpn-wireguard.path} ${vars.configDir}/qbittorrent/wireguard/wg0.conf
  #     ${pkgs.coreutils}/bin/chown ${toString vars.puid}:${toString vars.pgid} ${vars.configDir}/qbittorrent/wireguard/wg0.conf
  #     ${pkgs.coreutils}/bin/chmod 600 ${vars.configDir}/qbittorrent/wireguard/wg0.conf
  #   ''}"
  # ];

  # Setup transmission openvpn config directory
  systemd.tmpfiles.rules = lib.mkAfter [
    "d ${vars.configDir}/transmission-openvpn/openvpn 0750 ${toString vars.puid} ${toString vars.pgid}"
  ];

  # Copy AirVPN OpenVPN config before starting transmission container
  systemd.services.podman-transmission.serviceConfig.ExecStartPre = lib.mkAfter [
    "${pkgs.writeShellScript "copy-airvpn-config-transmission" ''
      ${pkgs.coreutils}/bin/rm -f ${vars.configDir}/transmission-openvpn/openvpn/airvpn.ovpn
      ${pkgs.coreutils}/bin/cp ${config.sops.secrets.transmission-openvpn-airvpn.path} ${vars.configDir}/transmission-openvpn/openvpn/airvpn.ovpn
      ${pkgs.coreutils}/bin/chown ${toString vars.puid}:${toString vars.pgid} ${vars.configDir}/transmission-openvpn/openvpn/airvpn.ovpn
      ${pkgs.coreutils}/bin/chmod 600 ${vars.configDir}/transmission-openvpn/openvpn/airvpn.ovpn
    ''}"
  ];
}
