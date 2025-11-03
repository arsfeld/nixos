{
  config,
  self,
  pkgs,
  lib,
  ...
}: let
  cfg = config.services.transmission-vpn;
  vars = config.media.config;
in {
  options.services.transmission-vpn = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Transmission with WireGuard VPN confinement";
    };
  };

  config = lib.mkIf cfg.enable {
    # Override transmission gateway config to use namespace IP instead of localhost
    # This is necessary because storage's Caddy needs to proxy to the VPN namespace
    # (192.168.15.1) rather than localhost (which doesn't go through DNAT rules)
    media.gateway.services.transmission.host = lib.mkForce "192.168.15.1";

    # Configure Transmission service with VPN confinement
    # Uses the shared "wg" VPN namespace configured in qbittorrent-vpn.nix
    services.transmission = {
      enable = true;
      package = pkgs.transmission_4;

      # Use Flood UI
      webHome = pkgs.flood-for-transmission;

      settings = {
        # Download directories
        download-dir = "${vars.storageDir}/media/Downloads";
        incomplete-dir-enabled = false; # Use .part extension instead of separate directory
        rename-partial-files = true; # Add .part extension to incomplete files
        watch-dir = "${vars.storageDir}/media/watch";
        watch-dir-enabled = true;

        # RPC/WebUI settings
        rpc-bind-address = "0.0.0.0";
        rpc-port = 9091;
        rpc-host-whitelist-enabled = false;
        rpc-whitelist-enabled = false;

        # AirVPN static port forwarding
        peer-port = 30158;
        peer-port-random-on-start = false;

        # Performance settings
        download-queue-enabled = true;
        download-queue-size = 10;
        seed-queue-enabled = true;
        seed-queue-size = 50;

        # Ratio and seed settings
        ratio-limit-enabled = false;
        idle-seeding-limit-enabled = false;

        # Misc settings
        umask = 2;
        encryption = 2; # Require encryption
      };

      # Set proper permissions for download directory
      downloadDirPermissions = "775";

      # Run as media user/group
      user = vars.user;
      group = vars.group;
    };

    # Override transmission service to add VPN confinement
    systemd.services.transmission = {
      # VPN confinement configuration - uses shared "wg" namespace
      vpnConfinement = {
        enable = true;
        vpnNamespace = "wg";
      };

      # Ensure directories exist before starting
      preStart = ''
        mkdir -p ${vars.storageDir}/media/Downloads
        mkdir -p ${vars.storageDir}/media/Downloads/radarr
        mkdir -p ${vars.storageDir}/media/Downloads/sonarr
        mkdir -p ${vars.storageDir}/media/watch
      '';

      serviceConfig = {
        # Bind mount storage directories for access from VPN namespace
        BindPaths = [
          "${vars.storageDir}/media"
          "${vars.storageDir}/files"
        ];

        # Additional security hardening
        PrivateTmp = true;
        NoNewPrivileges = true;

        # Restart on failure
        Restart = lib.mkForce "on-failure";
        RestartSec = "5s";
      };
    };
  };
}
