# Supabase dynamic instance management module
#
# This module provides infrastructure for managing multiple Supabase instances
# dynamically. It sets up the necessary services, users, and directories to
# run isolated Supabase deployments with Docker Compose.
#
# Features:
# - Dynamic instance creation and management
# - Automatic Caddy reverse proxy configuration
# - Docker Compose orchestration
# - Periodic maintenance tasks
# - Centralized logging and data storage
# - Multi-instance support with domain-based routing
#
# The module works in conjunction with the supabase-manager package to provide
# CLI tools for instance lifecycle management.
#
# Example usage:
#   services.supabase = {
#     enable = true;
#     domain = "mycompany.dev";
#     dataDir = "/data/supabase";
#   };
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.services.supabase;
in {
  options.services.supabase = {
    enable = mkEnableOption "dynamic Supabase instance management";

    domain = mkOption {
      type = types.str;
      default = "arsfeld.dev";
      description = ''
        Base domain for Supabase instances. Each instance will be accessible
        at <instance-name>.<domain> with subdomains for different services
        (e.g., api.<instance-name>.<domain>, studio.<instance-name>.<domain>).
      '';
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/supabase";
      description = ''
        Root directory for all Supabase instance data, including:
        - Instance configurations and docker-compose files
        - PostgreSQL data volumes
        - Caddy configurations
        - Logs and temporary files
      '';
    };

    user = mkOption {
      type = types.str;
      default = "supabase";
      description = ''
        System user that will own and run Supabase instances.
        This user will be added to the docker group automatically.
      '';
    };

    group = mkOption {
      type = types.str;
      default = "supabase";
      description = ''
        System group for Supabase instance files and processes.
      '';
    };
  };

  config = mkIf cfg.enable {
    # Enable Docker
    virtualisation.docker = {
      enable = true;
      autoPrune = {
        enable = true;
        dates = "weekly";
      };
    };

    # Create user and group
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.dataDir;
      createHome = true;
      extraGroups = ["docker"];
    };

    users.groups.${cfg.group} = {};

    # Install required packages
    environment.systemPackages = with pkgs; [
      docker-compose
      python3
      uv
      supabase-manager
    ];

    # Create directory structure
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataDir}/instances 0755 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataDir}/caddy 0755 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataDir}/templates 0755 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataDir}/logs 0755 ${cfg.user} ${cfg.group} -"
    ];

    # Configure Caddy to include dynamic configurations
    services.caddy = {
      enable = true;
      extraConfig = ''
        # Import all instance-specific configurations
        import ${cfg.dataDir}/caddy/*.conf
      '';
    };

    # Systemd service to ensure instances start on boot
    systemd.services.supabase-instances = {
      description = "Start all Supabase instances";
      after = ["docker.service" "network-online.target"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.dataDir;
        ExecStart = "${pkgs.supabase-manager}/bin/supabase-manager start-all";
        ExecStop = "${pkgs.supabase-manager}/bin/supabase-manager stop-all";
      };
    };

    # Timer for periodic maintenance
    systemd.timers.supabase-maintenance = {
      description = "Run Supabase maintenance tasks";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
      };
    };

    systemd.services.supabase-maintenance = {
      description = "Supabase maintenance tasks";
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.dataDir;
        ExecStart = "${pkgs.supabase-manager}/bin/supabase-manager maintenance";
      };
    };

    # Environment variables
    environment.sessionVariables = {
      SUPABASE_DATA_DIR = cfg.dataDir;
      SUPABASE_DOMAIN = cfg.domain;
    };
  };
}
