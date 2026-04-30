# Constellation Forgejo Actions runner module
#
# Registers a Forgejo Actions runner with the configured Forgejo instance.
# The registration token is consumed once on first start and exchanged for a
# long-lived auth token cached under the systemd state directory.
{
  pkgs,
  lib,
  config,
  ...
}: let
  cfg = config.constellation.forgejo-runner;
in {
  options.constellation.forgejo-runner = {
    enable = lib.mkEnableOption "Forgejo Actions runner";

    name = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Runner instance name shown in Forgejo's runner list.";
    };

    url = lib.mkOption {
      type = lib.types.str;
      example = "https://forgejo.example.com";
      description = "Forgejo server URL the runner registers with.";
    };

    capacity = lib.mkOption {
      type = lib.types.int;
      default = 2;
      description = "Maximum concurrent jobs accepted by this runner.";
    };

    labels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "ubuntu-latest:docker://node:20-bookworm"
        "nix:docker://nixos/nix:latest"
        "native:host"
      ];
      description = "Runner labels advertised to Forgejo for job matching.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.forgejo-runner-token = {};

    services.gitea-actions-runner = {
      package = pkgs.forgejo-runner;
      instances.${cfg.name} = {
        enable = true;
        inherit (cfg) name url labels;
        tokenFile = config.sops.secrets.forgejo-runner-token.path;
        settings = {
          runner.capacity = cfg.capacity;
          container.network = "host";
        };
      };
    };
  };
}
