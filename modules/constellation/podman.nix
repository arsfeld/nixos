{
  config,
  lib,
  pkgs,
  ...
}: let
  toml = pkgs.formats.toml {};
in {
  options.constellation.podman = {
    enable = lib.mkEnableOption "podman";
  };

  config = lib.mkIf config.constellation.podman.enable {
    virtualisation.podman = {
      enable = lib.mkDefault true;

      # Create a `docker` alias for podman, to use it as a drop-in replacement
      dockerCompat = true;
      networkSocket.enable = true;
      networkSocket.server = "ghostunnel";
      networkSocket.tls.cacert = "/var/lib/tailscale/certs/${config.networking.hostName}.bat-boa.ts.net.crt";
      networkSocket.tls.cert = "/var/lib/tailscale/certs/${config.networking.hostName}.bat-boa.ts.net.crt";
      networkSocket.tls.key = "/var/lib/tailscale/certs/${config.networking.hostName}.bat-boa.ts.net.key";

      # Required for containers under podman-compose to be able to talk to each other.
      defaultNetwork.settings.dns_enabled = true;

      dockerSocket.enable = true;

      autoPrune.enable = true;
    };

    environment.systemPackages = with pkgs; [
      podman-compose
    ];

    virtualisation.containers.registries.search = ["docker.io"];

    environment.etc."containers/registry.conf".source = toml.generate "registry.conf" {
      registry = [
        {
          prefix = "docker.io";
          location = "registry-1.docker.io";
          mirror = [
            {
              location = "mirror.gcr.io";
            }
          ];
        }
      ];
    };

    virtualisation.oci-containers.backend = lib.mkDefault "podman";

    systemd.timers."podman-image-pull" = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
      };
    };

    systemd.services."podman-image-pull" = {
      script = ''
        # Wait for podman to be available
        while ! ${pkgs.podman}/bin/podman info >/dev/null 2>&1; do
          sleep 1
        done

        exit_code=0

        ${lib.concatMapStrings (name: let
          container = config.virtualisation.oci-containers.containers.${name};
        in ''
          image_name="${container.image}"
          echo "Checking $image_name..."

          # Get current image ID if container is running
          current_id=$(${pkgs.podman}/bin/podman inspect "${name}" -f '{{.Image}}' 2>/dev/null || echo "none")

          # Pull new image
          if ! ${pkgs.podman}/bin/podman pull "$image_name"; then
            echo "Failed to pull $image_name"
            exit_code=1
            continue
          fi

          # Get new image ID
          new_id=$(${pkgs.podman}/bin/podman inspect "$image_name" -f '{{.Id}}' 2>/dev/null)
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
            if ! ${pkgs.systemd}/bin/systemctl restart "podman-${name}"; then
              echo "Failed to restart podman-${name}"
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
      wants = ["podman.service"];
      after = ["podman.service"];
    };
  };
}
