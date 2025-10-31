{
  config,
  self,
  pkgs,
  lib,
  ...
}: let
  cfg = config.services.qbittorrent-vpn;
  vars = config.media.config;
in {
  options.services.qbittorrent-vpn = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable qBittorrent with WireGuard VPN confinement";
    };
  };

  config = lib.mkIf cfg.enable {
    # Load AirVPN WireGuard secret
    age.secrets."airvpn-wireguard" = {
      file = "${self}/secrets/airvpn-wireguard.age";
      mode = "400";
    };

    # Override qbittorrent gateway config to use namespace IP instead of localhost
    # This is necessary because storage's Caddy needs to proxy to the VPN namespace
    # (192.168.15.1) rather than localhost (which doesn't go through DNAT rules)
    media.gateway.services.qbittorrent.host = lib.mkForce "192.168.15.1";

    # VPN namespace configuration using VPN-Confinement
    vpnNamespaces.wg = {
      enable = true;
      wireguardConfigFile = config.age.secrets.airvpn-wireguard.path;

      # Allow access from Tailscale network, Podman network, and local LAN
      accessibleFrom = [
        "100.64.0.0/10" # Tailscale CGNAT range
        "10.0.0.0/8" # Local networks (includes Podman 10.88.0.0/16)
        "192.168.0.0/16" # Additional local networks
      ];

      # Map ports from host to namespace for WebUI access
      portMappings = [
        {
          from = 8080;
          to = 8080;
        }
        {
          from = 9091;
          to = 9091;
        }
      ];

      # Do NOT expose ports through VPN for security
      openVPNPorts = [];
    };

    # Configure qBittorrent service with VPN confinement
    systemd.services.qbittorrent-nox = {
      description = "qBittorrent-nox service confined to VPN";
      wantedBy = ["multi-user.target"];

      # VPN confinement configuration
      vpnConfinement = {
        enable = true;
        vpnNamespace = "wg";
      };

      serviceConfig = {
        Type = "simple";
        User = vars.user;
        Group = vars.group;

        # Bind qBittorrent WebUI to all interfaces
        ExecStart = "${pkgs.qbittorrent-nox}/bin/qbittorrent-nox --webui-port=8080";

        Restart = "on-failure";
        RestartSec = "5s";

        # Security hardening
        PrivateTmp = true;
        NoNewPrivileges = true;

        # State directory for qBittorrent config and session data
        StateDirectory = "qbittorrent";
        StateDirectoryMode = "0750";
      };

      environment = {
        # qBittorrent data directory
        QBT_PROFILE = "/var/lib/qbittorrent";
        HOME = "/var/lib/qbittorrent";
      };
    };
  };
}
