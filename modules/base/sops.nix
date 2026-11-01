# Constellation sops module
#
# This module provides sops-nix infrastructure setup for hosts.
# It configures age encryption with automatic key generation from SSH host keys
# and sets the default secrets file path.
#
# The module is a thin wrapper around sops-nix that handles infrastructure setup.
# Use the standard sops.secrets options for defining secrets.
#
# Key features:
# - Automatic age key generation from SSH host keys
# - Sets defaultSopsFile to secrets/sops/<hostname>.yaml
# - Configures age key paths and generation
#
# Usage:
#   # Use standard sops-nix configuration for secrets
#   sops.secrets = {
#     # Host-specific secrets (uses defaultSopsFile)
#     ntfy-env = { mode = "0444"; };
#
#     # Common secrets (use exposed commonSopsFile)
#     shared-api-key = {
#       sopsFile = config.constellation.sops.commonSopsFile;
#       mode = "0400";
#     };
#   };
{self, ...}: {
  flake.modules.nixos.base = {
    key = "modules/base/sops";
    imports = [
      ({
        lib,
        config,
        ...
      }: let
        cfg = config.constellation.sops;
        hostname =
          if cfg.hostname != null
          then cfg.hostname
          else config.networking.hostName;
      in {
        options.constellation.sops = {
          hostname = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            description = ''
              Hostname to use for determining the default secrets file path.
              Defaults to config.networking.hostName if not set.
            '';
            default = null;
          };

          commonSopsFile = lib.mkOption {
            type = lib.types.path;
            description = ''
              Path to the common secrets file shared across all hosts.
              Use this in sops.secrets.<name>.sopsFile for cross-host secrets.
            '';
            default = "${self}/secrets/sops/common.yaml";
            readOnly = true;
          };
        };

        config = {
          # Configure sops-nix infrastructure
          sops = {
            # Set default secrets file to host-specific file
            defaultSopsFile = "${self}/secrets/sops/${hostname}.yaml";

            # Configure age encryption
            age = {
              # Use the host's SSH key for decryption
              sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
              # Generate age key from SSH key on first boot
              keyFile = "/var/lib/sops-nix/key.txt";
              generateKey = true;
            };

            # Secrets are defined directly via sops.secrets in host configuration
          };
        };
      })
    ];
  };
}
