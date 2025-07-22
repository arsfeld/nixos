{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.router-ui;
  
  router-ui = pkgs.callPackage ./. { };
  
  # Database configuration
  dataDir = "/var/lib/router-ui";
  dbPath = "${dataDir}/db";
  
  # Configuration file
  configFile = pkgs.writeText "router-ui-config.json" (builtins.toJSON {
    port = toString cfg.port;
    db_path = dbPath;
    static_dir = "${router-ui}/share/router-ui/web/static";
    templates_dir = "${router-ui}/share/router-ui/web/templates";
    tailscale_auth = cfg.tailscaleAuth;
  });
in {
  options.services.router-ui = {
    enable = mkEnableOption "Router UI - Web interface for router management";
    
    port = mkOption {
      type = types.port;
      default = 4000;
      description = "Port on which Router UI will listen";
    };
    
    tailscaleAuth = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Tailscale authentication";
    };
    
    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to open the firewall for Router UI";
    };
    
    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Environment file containing sensitive configuration.
        Can contain environment variables for the service.
      '';
    };
  };
  
  config = mkIf cfg.enable {
    # Create system user and group
    users.users.router-ui = {
      isSystemUser = true;
      group = "router-ui";
      home = dataDir;
      description = "Router UI service user";
    };
    
    users.groups.router-ui = {};
    
    # Create required directories
    systemd.tmpfiles.rules = [
      "d ${dataDir} 0700 router-ui router-ui -"
      "d ${dbPath} 0700 router-ui router-ui -"
      "d /etc/wireguard 0700 root root -"
      "d /etc/nftables.d 0755 root root -"
    ];
    
    # Systemd service
    systemd.services.router-ui = {
      description = "Router UI - Web interface for router management";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      
      serviceConfig = {
        Type = "exec";
        User = "router-ui";
        Group = "router-ui";
        WorkingDirectory = dataDir;
        
        # Network admin capabilities for WireGuard and nftables management
        AmbientCapabilities = [ "CAP_NET_ADMIN" "CAP_NET_RAW" ];
        CapabilityBoundingSet = [ "CAP_NET_ADMIN" "CAP_NET_RAW" ];
        
        # Security hardening
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        ReadWritePaths = [ 
          dataDir 
          "/etc/wireguard"
          "/etc/nftables.d"
          "/var/lib/kea"  # For reading DHCP leases
        ];
        
        # Environment
        Environment = [
          "HOME=${dataDir}"
        ];
        EnvironmentFile = mkIf (cfg.environmentFile != null) cfg.environmentFile;
        
        # Run the service
        ExecStart = "${router-ui}/bin/router_ui -config ${configFile}";
        
        Restart = "on-failure";
        RestartSec = 5;
        
        # Logging
        StandardOutput = "journal";
        StandardError = "journal";
        SyslogIdentifier = "router-ui";
      };
    };
    
    # Open firewall if requested
    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];
    
    # Add router-ui to nftables reload path
    systemd.services.nftables = mkIf config.networking.nftables.enable {
      reloadIfChanged = true;
      serviceConfig.ExecReload = mkForce ''
        ${pkgs.nftables}/bin/nft -f /etc/nftables.conf
        ${pkgs.nftables}/bin/nft -f /etc/nftables.d/router-ui.nft || true
      '';
    };
    
    # Integration with Caddy (if enabled)
    services.caddy.virtualHosts = mkIf (config.services.caddy.enable && cfg.openFirewall == false) {
      ":80".extraConfig = mkAfter ''
        handle /router-ui* {
          uri strip_prefix /router-ui
          reverse_proxy localhost:${toString cfg.port}
        }
      '';
    };
  };
}