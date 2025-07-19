{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.natpmp-server;
  
  natpmp-server = pkgs.callPackage ./default.nix { };
  
  configFlags = [
    "--listen-interface" cfg.listenInterface
    "--listen-port" (toString cfg.listenPort)
    "--external-interface" cfg.externalInterface
    "--nat-table" cfg.nftables.natTable
    "--nat-chain" cfg.nftables.natChain
    "--filter-table" cfg.nftables.filterTable
    "--filter-chain" cfg.nftables.filterChain
    "--max-mappings-per-ip" (toString cfg.maxMappingsPerClient)
    "--default-lifetime" (toString cfg.defaultLifetime)
    "--max-lifetime" (toString cfg.maxLifetime)
    "--state-dir" "/var/lib/natpmp-server"
    "--cleanup-interval" (toString cfg.cleanupInterval)
  ] ++ optionals (cfg.metricsPort != null) [
    "--metrics-port" (toString cfg.metricsPort)
  ];
in
{
  options.services.natpmp-server = {
    enable = mkEnableOption "NAT-PMP server";
    
    listenInterface = mkOption {
      type = types.str;
      default = "br-lan";
      description = "Interface to listen for NAT-PMP requests";
    };
    
    listenPort = mkOption {
      type = types.port;
      default = 5351;
      description = "Port to listen on for NAT-PMP requests";
    };
    
    externalInterface = mkOption {
      type = types.str;
      description = "External interface for NAT";
      example = "eth0";
    };
    
    nftables = {
      natTable = mkOption {
        type = types.str;
        default = "nat";
        description = "nftables NAT table name";
      };
      
      natChain = mkOption {
        type = types.str;
        default = "NATPMP";
        description = "nftables NAT chain name";
      };
      
      filterTable = mkOption {
        type = types.str;
        default = "filter";
        description = "nftables filter table name";
      };
      
      filterChain = mkOption {
        type = types.str;
        default = "NATPMP";
        description = "nftables filter chain name";
      };
    };
    
    allowedPortRanges = mkOption {
      type = types.listOf (types.submodule {
        options = {
          from = mkOption { 
            type = types.port;
            description = "Start of port range";
          };
          to = mkOption { 
            type = types.port;
            description = "End of port range";
          };
        };
      });
      default = [{ from = 1024; to = 65535; }];
      description = "Port ranges allowed for mapping";
    };
    
    maxMappingsPerClient = mkOption {
      type = types.int;
      default = 100;
      description = "Maximum number of mappings per client IP";
    };
    
    defaultLifetime = mkOption {
      type = types.int;
      default = 3600;
      description = "Default mapping lifetime in seconds";
    };
    
    maxLifetime = mkOption {
      type = types.int;
      default = 86400;
      description = "Maximum mapping lifetime in seconds";
    };
    
    cleanupInterval = mkOption {
      type = types.int;
      default = 60;
      description = "Interval for cleaning up expired mappings in seconds";
    };
    
    metricsPort = mkOption {
      type = types.nullOr types.port;
      default = null;
      description = "Port for Prometheus metrics endpoint. Set to null to disable metrics.";
      example = 9100;
    };
  };
  
  config = mkIf cfg.enable {
    systemd.services.natpmp-server = {
      description = "NAT-PMP Server";
      after = [ "network.target" "nftables.service" ];
      wants = [ "nftables.service" ];
      wantedBy = [ "multi-user.target" ];
      # Restart when nftables is restarted
      partOf = [ "nftables.service" ];
      # Bind to nftables so we stop/start together
      bindsTo = [ "nftables.service" ];
      
      path = with pkgs; [ nftables ];
      
      serviceConfig = {
        ExecStart = "${natpmp-server}/bin/natpmp-server ${escapeShellArgs configFlags}";
        StateDirectory = "natpmp-server";
        Restart = "always";
        RestartSec = "5s";
        
        # Security hardening
        DynamicUser = true;
        AmbientCapabilities = [ "CAP_NET_ADMIN" ];
        CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
        PrivateDevices = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_NETLINK" ];
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RemoveIPC = true;
        PrivateMounts = true;
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "@network-io"
        ];
      };
    };
    
    networking.firewall = {
      allowedUDPPorts = [ cfg.listenPort ];
      allowedTCPPorts = optional (cfg.metricsPort != null) cfg.metricsPort;
    };
    
    # Note: The nftables chains need to be created manually in the router's nftables ruleset
    # or the service will create them automatically on startup
  };
}