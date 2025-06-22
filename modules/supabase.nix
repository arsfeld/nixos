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
      description = "Base domain for Supabase instances";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/supabase";
      description = "Directory for Supabase instance data";
    };

    user = mkOption {
      type = types.str;
      default = "supabase";
      description = "User to run Supabase instances";
    };

    group = mkOption {
      type = types.str;
      default = "supabase";
      description = "Group for Supabase instances";
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
