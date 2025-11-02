# Constellation sops module
#
# This module provides sops-nix secret management configuration for hosts.
# It uses age encryption with host SSH keys for automatic key generation.
#
# Key features:
# - Age key auto-generation from host SSH keys
# - Host-specific secret files (secrets/sops/<hostname>.yaml)
# - Flexible secret definition via secretsConfig option
#
# Usage:
#   constellation.sops = {
#     enable = true;
#     hostname = "cloud";  # defaults to config.networking.hostName
#     secretsConfig = {
#       ntfy-env = { mode = "0444"; };
#       siyuan-auth-code = { owner = "root"; group = "root"; };
#     };
#   };
{
  lib,
  config,
  self,
  ...
}:
with lib; let
  cfg = config.constellation.sops;
  hostname =
    if cfg.hostname != null
    then cfg.hostname
    else config.networking.hostName;
in {
  options.constellation.sops = {
    enable = mkOption {
      type = types.bool;
      description = ''
        Enable sops-nix secret management.
        This sets up age-based encryption using the host's SSH key
        and loads secrets from secrets/sops/<hostname>.yaml.
      '';
      default = false;
    };

    hostname = mkOption {
      type = types.nullOr types.str;
      description = ''
        Hostname to use for determining the secrets file path.
        Defaults to config.networking.hostName if not set.
      '';
      default = null;
    };

    secretsConfig = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          mode = mkOption {
            type = types.str;
            description = "File mode for the decrypted secret";
            default = "0400";
          };
          owner = mkOption {
            type = types.str;
            description = "Owner of the decrypted secret file";
            default = "root";
          };
          group = mkOption {
            type = types.str;
            description = "Group of the decrypted secret file";
            default = "root";
          };
        };
      });
      description = ''
        Attribute set of secrets to load from the sops file.
        Each key is the secret name, and the value configures permissions.
      '';
      default = {};
    };
  };

  config = mkIf cfg.enable {
    # Configure sops-nix
    sops = {
      defaultSopsFile = "${self}/secrets/sops/${hostname}.yaml";
      age = {
        # Use the host's SSH key for decryption
        sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
        # Generate age key from SSH key on first boot
        keyFile = "/var/lib/sops-nix/key.txt";
        generateKey = true;
      };

      # Define secrets from the secrets file
      secrets =
        mapAttrs (name: secretCfg: {
          mode = secretCfg.mode;
          owner = secretCfg.owner;
          group = secretCfg.group;
        })
        cfg.secretsConfig;
    };
  };
}
