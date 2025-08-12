{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.constellation.beszel;
in {
  options.constellation.beszel = {
    enable = lib.mkEnableOption "Beszel monitoring system";

    hub = {
      enable = lib.mkEnableOption "Beszel hub service" // {default = cfg.enable;};
      port = lib.mkOption {
        type = lib.types.port;
        default = 8090;
        description = "Port for Beszel hub to listen on";
      };
      user = lib.mkOption {
        type = lib.types.str;
        default = "beszel";
        description = "User account for Beszel hub service";
      };
      dataDir = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/beszel";
        description = "Data directory for Beszel hub";
      };
    };

    agent = {
      enable = lib.mkEnableOption "Beszel agent service" // {default = cfg.enable;};
      port = lib.mkOption {
        type = lib.types.port;
        default = 45876;
        description = "Port for Beszel agent to listen on";
      };
      key = lib.mkOption {
        type = lib.types.str;
        default = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGKIjUSMdRqYMmZopjoXBVbEW2SpjE4mxrPclsnQCvW9";
        description = "SSH public key for Beszel agent authentication";
      };
      user = lib.mkOption {
        type = lib.types.str;
        default = "beszel-agent";
        description = "User account for Beszel agent service";
      };
      dataDir = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/beszel-agent";
        description = "Data directory for Beszel agent";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    # Hub configuration
    (lib.mkIf cfg.hub.enable {
      users.users.${cfg.hub.user} = {
        group = cfg.hub.user;
        home = cfg.hub.dataDir;
        isSystemUser = true;
        createHome = true;
      };

      users.groups.${cfg.hub.user} = {};

      systemd.services.beszel-hub = {
        description = "Beszel Hub Monitoring Service";
        wantedBy = ["multi-user.target"];
        after = ["network.target"];
        serviceConfig = {
          User = cfg.hub.user;
          ExecStart = "${pkgs.beszel}/bin/beszel-hub serve --http 0.0.0.0:${toString cfg.hub.port}";
          WorkingDirectory = cfg.hub.dataDir;
          Restart = "on-failure";
          RestartSec = 5;
        };
      };
    })

    # Agent configuration
    (lib.mkIf cfg.agent.enable {
      users.users.${cfg.agent.user} = {
        group = cfg.agent.user;
        home = cfg.agent.dataDir;
        isSystemUser = true;
        createHome = true;
      };

      users.groups.${cfg.agent.user} = {};

      systemd.services.beszel-agent = {
        description = "Beszel Agent Monitoring Service";
        wantedBy = ["multi-user.target"];
        after = ["network.target"];
        serviceConfig = {
          Environment = [
            "PORT=${toString cfg.agent.port}"
            "KEY='${cfg.agent.key}'"
          ];
          User = cfg.agent.user;
          ExecStart = "${pkgs.beszel}/bin/beszel-agent";
          WorkingDirectory = cfg.agent.dataDir;
          Restart = "on-failure";
          RestartSec = 5;
        };
      };
    })
  ]);
}
