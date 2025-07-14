# Constellation users module
#
# This module manages user accounts and authentication across all Constellation
# hosts. It provides consistent user configuration, SSH key management, and
# privilege settings.
#
# Key features:
# - Primary user account with administrative privileges
# - SSH key-based authentication for secure remote access
# - Passwordless sudo for wheel group members
# - Group memberships for container runtimes and services
# - Fish shell as default for better interactive experience
# - Consistent UID/GID assignments across hosts
#
# Security considerations:
# - SSH password authentication is typically disabled system-wide
# - All administrative access requires SSH key authentication
# - User has access to container runtimes for service management
{
  config,
  pkgs,
  lib,
  ...
}: {
  options.constellation.users = with lib; {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Enable standard user configuration for Constellation hosts.
        This creates the primary administrative user account with
        appropriate permissions and SSH access.
      '';
    };
  };

  config = lib.mkIf config.constellation.users.enable {
    security.sudo = {
      enable = true;
      wheelNeedsPassword = false;
    };

    users.users.root.openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w"
    ];

    users.users.arosenfeld = {
      isNormalUser = true;
      shell = pkgs.fish;
      description = "Alexandre Rosenfeld";
      extraGroups = ["users" "wheel" "docker" "lxd" "media" "libvirtd" "networkmanager" "incus-admin" "podman"];
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKdOiSH7TgoulL4YasuXaeWC/j3BjGUi9v6168BifciA alexandre.rosenfeld@issuerdirect.com"
      ];
      hashedPassword = "$6$Csmhna5YUVoHnZ/S$lrSk0wko.Z/oL.Omf2jAdLc/mSpZsrw8sOXlknmfdHEjMopP7hESNk9PCArGBnZKm566Fo2QoubQWt0SLjbng.";
      uid = 1000;
    };
    users.groups.arosenfeld.gid = 1000;

    # Disable man pages generation
    documentation.man.generateCaches = false;
  };
}
