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
    # Configure Transmission service with VPN confinement
    # Uses the shared "wg" VPN namespace configured in qbittorrent-vpn.nix
    services.transmission = {
      enable = true;
      package = pkgs.transmission_4;

      # Use Flood UI
      webHome = pkgs.flood-for-transmission;

      settings = {
        # Download directories
        download-dir = "${vars.storageDir}/downloads";
        incomplete-dir = "${vars.storageDir}/incomplete";
        watch-dir = "${vars.storageDir}/watch";
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
        mkdir -p ${vars.storageDir}/downloads
        mkdir -p ${vars.storageDir}/incomplete
        mkdir -p ${vars.storageDir}/watch
        chown -R ${vars.user}:${vars.group} ${vars.storageDir}/downloads ${vars.storageDir}/incomplete ${vars.storageDir}/watch
      '';

      serviceConfig = {
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
