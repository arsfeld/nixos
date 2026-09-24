# Constellation Docker module
#
# This module provides Docker container runtime configuration with automated
# image management and updates. It includes Docker Compose support and automatic
# container updates for OCI containers defined in the configuration.
#
# Key features:
# - Docker daemon with automatic pruning of unused resources
# - Docker Compose for multi-container applications
# - Registry mirror configuration for faster pulls
# - Daily automated image updates with container restarts
# - Smart update detection - only restarts containers when new images are available
# - Systemd integration for container lifecycle management
#
# The module automatically tracks all containers defined via the NixOS
# virtualisation.oci-containers interface and keeps them updated with the
# latest available images.
{
  config,
  lib,
  pkgs,
  ...
}: {
  options.constellation.docker = {
    enable = lib.mkOption {
      type = lib.types.bool;
      description = ''
        Enable Docker container runtime with automated image updates.
        This includes Docker Compose support and daily image pull checks
        for all configured OCI containers.
      '';
      default = false;
    };
  };

  config = lib.mkIf config.constellation.docker.enable {
    virtualisation.docker = {
      enable = lib.mkDefault true;

      # Enable automatic pruning of unused images, containers, networks, and volumes
      autoPrune.enable = true;
    };

    environment.systemPackages = with pkgs; [
      docker-compose
    ];

    # Configure Docker registry mirrors
    virtualisation.docker.daemon.settings = {
      registry-mirrors = [
        "https://mirror.gcr.io"
      ];
    };

    virtualisation.oci-containers.backend = lib.mkDefault "docker";

    systemd.timers."docker-image-pull" = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
      };
    };

    systemd.services."docker-image-pull" = {
      script = ''
        # Wait for docker to be available
        while ! ${pkgs.docker}/bin/docker info >/dev/null 2>&1; do
          sleep 1
        done

        exit_code=0

        ${lib.concatMapStrings (name: let
          container = config.virtualisation.oci-containers.containers.${name};
        in ''
          image_name="${container.image}"
          echo "Checking $image_name..."

          # Get current image ID if container is running
          current_id=$(${pkgs.docker}/bin/docker inspect "${name}" -f '{{.Image}}' 2>/dev/null || echo "none")

          # Pull new image
          if ! ${pkgs.docker}/bin/docker pull "$image_name"; then
            echo "Failed to pull $image_name"
            exit_code=1
            continue
          fi

          # Get new image ID
          new_id=$(${pkgs.docker}/bin/docker inspect "$image_name" -f '{{.Id}}' 2>/dev/null)
          if [ $? -ne 0 ]; then
            echo "Failed to inspect new image $image_name"
            exit_code=1
            continue
          fi

          echo "--------------------------------"
          echo "Current: $current_id"
          echo "New:     $new_id"
          echo "--------------------------------"
          echo ""

          if [ "$current_id" != "none" ] && [ "$current_id" != "$new_id" ]; then
            echo "New version available for $image_name"
            echo "Current: $current_id"
            echo "New: $new_id"
            echo "Restarting container ${name}..."
            if ! ${pkgs.systemd}/bin/systemctl restart "docker-${name}"; then
              echo "Failed to restart docker-${name}"
              exit_code=1
              continue
            fi
          fi
        '') (builtins.attrNames config.virtualisation.oci-containers.containers)}

        exit $exit_code
      '';
      serviceConfig = {
        Type = "oneshot";
        User = "root";
      };
      wants = ["docker.service"];
      after = ["docker.service"];
    };
  };
}
