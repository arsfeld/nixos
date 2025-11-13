# Constellation Omada Controller module
#
# This module provides TP-Link Omada Controller, a centralized management platform
# for TP-Link Omada network devices (access points, switches, routers).
#
# Key features:
# - Native NixOS integration (no Docker containers)
# - Declarative configuration
# - Integrated MongoDB database (configurable version for AVX/non-AVX CPUs)
# - Automated systemd service management
# - Proper separation of read-only code and mutable state
#
# Web interface:
# - HTTP: port 8088
# - HTTPS: port 8043
# - Default credentials: admin/admin (change on first login)
#
# Network requirements:
# - Host networking for device discovery
# - Multiple UDP/TCP ports for device communication (see firewall configuration)
{
  lib,
  config,
  pkgs,
  ...
}:
with lib; let
  cfg = config.constellation.omada-controller;

  # MongoDB version selection based on CPU capabilities
  # MongoDB 6.0 for non-AVX CPUs, MongoDB 7.0+ for AVX-capable CPUs
  # Note: MongoDB 8.0+ requires AVX CPU instructions
  mongodbPackage =
    if cfg.useMongoDb6
    then pkgs.mongodb-6_0
    else pkgs.mongodb;

  # Omada Controller package from Nix store
  omadaPackage = pkgs.omada-controller;

  # Data directory for mutable state
  # Note: control.sh expects OMADA_HOME to contain data/, logs/, work/ subdirectories
  # So we set OMADA_HOME to this directory and symlink lib/, properties/, bin/ from the package
  dataDir = "/var/lib/omada";
in {
  options.constellation.omada-controller = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable TP-Link Omada Controller service.

        This provides a web-based management interface for TP-Link Omada network devices
        including access points, switches, and routers.
      '';
    };

    useMongoDb6 = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Use MongoDB 6.0 instead of latest version.

        Set to true for CPUs without AVX support (e.g., Intel Celeron N5105).
        MongoDB 8.0+ requires AVX CPU instructions, while 6.0 works on older CPUs.
      '';
    };

    httpPort = mkOption {
      type = types.port;
      default = 8088;
      description = "HTTP port for the web interface";
    };

    httpsPort = mkOption {
      type = types.port;
      default = 8043;
      description = "HTTPS port for the web interface";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Open firewall ports required for Omada Controller.
        This includes web interface ports and device discovery/management ports.
      '';
    };
  };

  config = mkIf cfg.enable {
    # Ensure the package is available
    nixpkgs.config.allowUnfreePredicate = pkg:
      builtins.elem (lib.getName pkg) [
        "omada-controller"
      ];

    # Create Omada user
    users.users.omada = {
      isSystemUser = true;
      group = "omada";
      description = "Omada Controller service user";
      home = dataDir;
    };

    users.groups.omada = {};

    # MongoDB service
    services.mongodb = {
      enable = true;
      package = mongodbPackage;

      # Bind to localhost only - Omada will connect locally
      bind_ip = "127.0.0.1";

      # Use default data directory (/var/db/mongodb)
      # This is managed by the mongodb service user, separate from omada user

      # Omada Controller expects MongoDB on default port 27017
      # No authentication required for local connection
    };

    # Omada Controller systemd service
    systemd.services.omada-controller = {
      description = "TP-Link Omada Controller";
      documentation = ["https://www.tp-link.com/us/omada-sdn/"];

      after = ["network.target" "mongodb.service"];
      wants = ["mongodb.service"];
      wantedBy = ["multi-user.target"];

      # Ensure MongoDB is fully started before Omada
      requires = ["mongodb.service"];

      environment = {
        JAVA_HOME = "${pkgs.jre}";
        OMADA_HOME = dataDir;
        XDG_CONFIG_HOME = "${dataDir}/chromium";
      };

      path = [pkgs.jre pkgs.curl pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.procps];

      serviceConfig = {
        Type = "forking";
        User = "omada";
        Group = "omada";

        # Working directory
        WorkingDirectory = dataDir;

        # Main process - use the symlinked control.sh
        ExecStart = "${dataDir}/bin/control.sh start";
        ExecStop = "${dataDir}/bin/control.sh stop";

        # PID file
        PIDFile = "/var/run/omada.pid";

        # Security settings
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;

        # Allow writes to our data directories
        ReadWritePaths = [
          dataDir
          "/var/run"
          "/tmp"
        ];

        # Resource limits
        LimitNOFILE = "8192";

        # Restart policy
        Restart = "on-failure";
        RestartSec = "10s";

        # Timeout for startup (Omada can take a while to initialize)
        TimeoutStartSec = "300s";
        TimeoutStopSec = "60s";
      };

      preStart = ''
        # Create mutable data directories
        mkdir -p ${dataDir}/{data,logs,work,chromium}
        mkdir -p ${dataDir}/data/{html,keystore,pdf,cluster,db,autobackup}

        # Create symlinks to read-only components from Nix store
        ln -sfn ${omadaPackage}/lib ${dataDir}/lib
        ln -sfn ${omadaPackage}/properties ${dataDir}/properties
        ln -sfn ${omadaPackage}/bin ${dataDir}/bin

        # Copy static resources if not present (these need to be writable for updates)
        if [ ! -d ${dataDir}/data/static ]; then
          mkdir -p ${dataDir}/data/static
          cp -r ${omadaPackage}/static/* ${dataDir}/data/static/
        fi

        # Set ownership for all mutable directories
        chown -R omada:omada ${dataDir}/data
        chown -R omada:omada ${dataDir}/logs
        chown -R omada:omada ${dataDir}/work
        chown -R omada:omada ${dataDir}/chromium
      '';
    };

    # Firewall configuration
    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [
        cfg.httpPort # HTTP web interface
        cfg.httpsPort # HTTPS web interface
        27002 # Manager v1 communication
      ];

      allowedUDPPorts = [
        27001 # Device discovery
        29810
        29811
        29812 # Device discovery and adoption
        29813
        29814
        29815 # Device discovery and adoption
        29816
        29817 # Device discovery and adoption
      ];
    };

    # State directories managed by tmpfiles
    systemd.tmpfiles.rules = [
      "d ${dataDir} 0755 omada omada -"
      "d ${dataDir}/data 0755 omada omada -"
      "d ${dataDir}/logs 0755 omada omada -"
      "d ${dataDir}/work 0755 omada omada -"
    ];
  };
}
