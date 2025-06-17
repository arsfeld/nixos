{
  self,
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.constellation.supabase;

  # Import helper functions
  utils = import ./__utils.nix {inherit self lib config;};

  # Import instance utilities
  instanceUtils = import ./__instance.nix {inherit self lib pkgs;};

  # Generate gateway services for enabled instances
  gatewayServices = utils.generateGatewayServices cfg.instances;
in {
  options.constellation.supabase = {
    enable = mkEnableOption "Supabase instances";

    containerBackend = mkOption {
      type = types.enum ["podman" "docker"];
      default = config.virtualisation.oci-containers.backend;
      description = "Container backend to use (podman or docker)";
    };

    defaultDomain = mkOption {
      type = types.str;
      default = config.media.config.domain or "localhost";
      description = "Default domain for Supabase instances";
    };

    instances = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Enable this Supabase instance";
          };

          subdomain = mkOption {
            type = types.str;
            description = "Subdomain for this instance";
            example = "supabase";
          };

          port = mkOption {
            type = types.int;
            default = 0; # Auto-assign
            description = "Port for this instance (0 for auto-assignment)";
          };

          logLevel = mkOption {
            type = types.enum ["debug" "info" "warn" "error"];
            default = "info";
            description = "Log level for this instance";
          };

          # Secret reference (agenix secret name for .env file)
          envFile = mkOption {
            type = types.str;
            description = "Name of agenix secret containing the complete .env file";
            example = "supabase-prod-env";
          };

          # Storage configuration
          storage = mkOption {
            type = types.submodule {
              options = {
                enable = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Enable storage service";
                };

                bucket = mkOption {
                  type = types.str;
                  description = "Default storage bucket name";
                };
              };
            };
            default = {};
            description = "Storage configuration";
          };

          # Service toggles
          services = mkOption {
            type = types.submodule {
              options = {
                realtime = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Enable realtime subscriptions";
                };

                auth = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Enable authentication service";
                };

                restApi = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Enable REST API";
                };

                storage = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Enable storage service";
                };
              };
            };
            default = {};
            description = "Service configuration";
          };
        };
      });
      default = {};
      description = "Supabase instance configurations";
    };
  };

  config = mkIf cfg.enable {
    # Import secrets for all enabled instances
    age.secrets = utils.generateSecrets cfg.instances;

    # Generate systemd services for each instance
    systemd.services = utils.generateSystemdServices cfg.instances instanceUtils;

    # Generate tmpfiles rules for all instances
    systemd.tmpfiles.rules = flatten (
      mapAttrsToList (
        name: instanceCfg:
          if instanceCfg.enable
          then instanceUtils.generateTmpfilesRules name instanceCfg config
          else []
      )
      cfg.instances
    );

    # Generate users and groups for instances
    users = utils.generateUsers cfg.instances;

    # Configure gateway services if media gateway is enabled
    media.gateway.services = mkIf (config.media.gateway.enable or false) gatewayServices;

    # Open firewall ports for instances
    networking.firewall.allowedTCPPorts = utils.getInstancePorts cfg.instances;

    # Container backend is handled by constellation.podman or constellation.docker module
    # Enable socket for docker-compose compatibility
    systemd.sockets = mkIf (cfg.containerBackend == "podman") {
      podman = {
        enable = true;
        wantedBy = ["sockets.target"];
      };
    };

    # Environment packages
    environment.systemPackages = with pkgs; [
      postgresql_17_jit
      docker-compose
      jq
    ];
  };
}
