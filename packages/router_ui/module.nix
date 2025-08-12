{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.vpn-manager;

  vpn-manager = pkgs.callPackage ./default.nix {};
in {
  options.services.vpn-manager = {
    enable = lib.mkEnableOption "Streamlit VPN Manager";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8501;
      description = "Port for the Streamlit web interface";
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/vpn-manager";
      description = "Directory for storing VPN manager state";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open firewall port for web interface";
    };
  };

  config = lib.mkIf cfg.enable {
    # Create state directory
    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0755 root root -"
    ];

    # Systemd service
    systemd.services.vpn-manager = {
      description = "Streamlit VPN Manager";
      after = ["network.target"];
      wantedBy = ["multi-user.target"];

      environment = {
        STREAMLIT_SERVER_PORT = toString cfg.port;
        STREAMLIT_SERVER_ADDRESS = "0.0.0.0";
        STREAMLIT_SERVER_HEADLESS = "true";
        STREAMLIT_SERVER_BASE_URL_PATH = "vpn-manager";
        STREAMLIT_BROWSER_GATHER_USAGE_STATS = "false";
        VPN_MANAGER_STATE_FILE = "/var/lib/vpn-manager/state.json";
        HOME = "/var/lib/vpn-manager";
      };

      serviceConfig = {
        Type = "simple";
        ExecStart = "${vpn-manager}/bin/vpn-manager";
        Restart = "on-failure";
        RestartSec = 5;

        # Run as a dedicated user for better security
        DynamicUser = true;
        StateDirectory = "vpn-manager";

        # Capabilities for network management (including WireGuard)
        AmbientCapabilities = ["CAP_NET_ADMIN" "CAP_NET_RAW" "CAP_SYS_MODULE"];
        CapabilityBoundingSet = ["CAP_NET_ADMIN" "CAP_NET_RAW" "CAP_SYS_MODULE"];

        # Security hardening
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = ["/tmp"];
        PrivateTmp = true;
        NoNewPrivileges = true;

        # Allow reading DHCP leases
        ReadOnlyPaths = [
          "/var/lib/misc" # dnsmasq leases
          "/var/lib/kea" # Kea leases
        ];
      };
    };

    # Open firewall if requested
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [cfg.port];

    # Add to reverse proxy if Caddy is enabled
    services.caddy.virtualHosts = lib.mkIf (config.services.caddy.enable) {
      "vpn-manager.local" = {
        extraConfig = ''
          reverse_proxy localhost:${toString cfg.port}
        '';
      };
    };
  };
}
