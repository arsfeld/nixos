# Media containers module
#
# This module provides a unified interface for managing containerized media services.
# It abstracts away the complexity of container configuration, networking, and
# integration with the gateway system.
#
# Key features:
# - Declarative container configuration with sensible defaults
# - Automatic port assignment based on service names
# - Gateway integration for authentication and routing
# - Support for hardware acceleration (GPU passthrough)
# - Volume management with proper permissions
# - Environment variable and secrets handling
# - Automatic container updates via watchtower
#
# Containers can be distributed across multiple hosts and are automatically
# exposed through the gateway with proper authentication and SSL termination.
{
  self,
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  _config = config;
  vars = config.media.config;
  utils = import "${self}/modules/media/__utils.nix" {inherit config lib pkgs;};
  nameToPort = import "${self}/common/nameToPort.nix";
  cfg = config.media.containers;
  exposedContainers =
    filterAttrs
    (name: container: container.enable && container.listenPort != null)
    cfg;
  deployedContainers =
    filterAttrs
    (name: container: container.enable && container.host == config.networking.hostName)
    cfg;
in {
  imports = [
    ./config.nix
    ./gateway.nix
  ];

  options.media.containers = mkOption {
    type = types.attrsOf (types.submodule ({config, ...}: {
      options = {
        enable = mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Whether to enable this media container.
            Disabled containers are completely removed from the system.
          '';
        };
        name = mkOption {
          type = types.str;
          default = config._module.args.name;
          description = ''
            Name of the container. Used for service naming, DNS entries,
            and container identification. Defaults to the attribute name.
          '';
        };
        listenPort = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = ''
            Port the container's service listens on internally.
            If null, the container won't be exposed through the gateway.
          '';
        };
        exposePort = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = ''
            Port to expose on the host system.
            If null, defaults to listenPort. Use a different value to avoid conflicts.
          '';
        };
        image = mkOption {
          type = types.str;
          default = "ghcr.io/linuxserver/${config.name}";
          description = ''
            Docker image to use for this container.
            Defaults to the LinuxServer.io image for the service name.
          '';
        };
        volumes = mkOption {
          type = types.listOf types.str;
          default = [];
          description = ''
            Additional volumes to mount in the container.
            Format: "host_path:container_path:options"
          '';
        };
        environment = mkOption {
          type = types.attrs;
          default = {};
          description = ''
            Additional environment variables to pass to the container.
            These are merged with the default media service environment.
          '';
        };
        environmentFiles = mkOption {
          type = types.listOf types.str;
          default = [];
          description = ''
            List of files containing environment variables to load.
            Useful for passing secrets without exposing them in the configuration.
          '';
        };
        extraOptions = mkOption {
          type = types.listOf types.str;
          default = [];
          description = ''
            Additional options to pass to the container runtime.
            For example: ["--gpus=all"] for GPU support.
          '';
        };
        configDir = mkOption {
          type = types.nullOr types.str;
          default = "/config";
          description = ''
            Path inside the container where configuration files are stored.
            This directory will be mapped to a host volume for persistence.
          '';
        };
        mediaVolumes = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Whether to mount standard media directories (downloads, movies, tv, etc.)
            into the container. Useful for media servers and download clients.
          '';
        };
        network = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Docker network to attach the container to.
            If null, uses the default bridge network.
          '';
        };
        privileged = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Run the container with extended privileges.
            Required for some containers that need low-level system access.
            WARNING: Use with caution as it reduces container isolation.
          '';
        };
        devices = mkOption {
          type = types.listOf types.str;
          default = [];
          description = ''
            List of host devices to pass through to the container.
            Format: "/dev/device:/dev/device:rwm"
            Commonly used for GPU or hardware transcoding devices.
          '';
        };
        host = mkOption {
          type = types.str;
          default = _config.networking.hostName;
          description = ''
            Hostname where this container should be deployed.
            Defaults to the current host. Use to distribute containers across multiple machines.
          '';
        };
        settings = mkOption {
          type = utils.gatewayConfig;
          default = {};
          description = "Extra settings for the media gateway";
        };
      };
    }));
    default = {};
    description = "Media container definitions";
  };

  config = mkIf (cfg != {}) {
    media.gateway = {
      enable = mkDefault (length (attrValues exposedContainers) > 0);

      services =
        mapAttrs (name: container: {
          host = container.host;
          port = mkIf (container.exposePort != null) container.exposePort;
          settings = mkDefault container.settings;
        })
        exposedContainers;
    };

    systemd.tmpfiles.rules = let
      createDir = path: "d ${path} 0775 ${vars.user} ${vars.group} -";
      getVolumeDir = volume: builtins.head (builtins.split ":" volume);
    in
      flatten (
        mapAttrsToList (
          name: container:
            (optional (container.configDir != null) (createDir "${vars.configDir}/${name}"))
            ++ (map (volume: createDir (getVolumeDir volume)) container.volumes)
        )
        deployedContainers
      );

    # Add systemd dependencies for services with mediaVolumes enabled
    systemd.services = mkMerge (
      mapAttrsToList (
        name: container:
          mkIf (container.enable && container.mediaVolumes) {
            "podman-${name}" = {
              after = ["mnt-storage.mount"];
              requires = ["mnt-storage.mount"];
            };
          }
      )
      deployedContainers
    );

    # Create services.json with debug information
    environment.etc."services.json".source = let
      debugInfo =
        mapAttrs (name: container: {
          listenPort = container.listenPort;
          exposePort =
            if container.exposePort != null
            then container.exposePort
            else nameToPort name;
          portMapping = "${toString (
            if container.exposePort != null
            then container.exposePort
            else nameToPort name
          )}:${toString container.listenPort}";
        })
        exposedContainers;
    in
      pkgs.writeText "services.json" (builtins.toJSON debugInfo);

    virtualisation.oci-containers.containers = mkMerge (
      mapAttrsToList (
        name: container:
          mkIf container.enable {
            ${name} = {
              image = container.image;
              environment =
                {
                  PUID = toString vars.puid;
                  PGID = toString vars.pgid;
                  TZ = vars.tz;
                }
                // container.environment;
              environmentFiles = container.environmentFiles;
              ports = let
                exposePort = config.media.gateway.services.${name}.port;
                portMapping = "${toString exposePort}:${toString container.listenPort}";
              in
                optional (container.listenPort != null) portMapping;
              volumes =
                container.volumes
                ++ (optional (container.configDir != null) "${vars.configDir}/${name}:${container.configDir}")
                ++ (optionals container.mediaVolumes [
                  "${vars.dataDir}/files:/files"
                  "${vars.dataDir}/files:${vars.dataDir}/files"
                  "${vars.storageDir}/media:/media"
                  "${vars.storageDir}/media:${vars.storageDir}/media"
                ]);
              extraOptions = flatten [
                (optional (container.network != null) "--network=${container.network}")
                (optional container.privileged "--privileged")
                (map (device: "--device=${device}") container.devices)
                container.extraOptions
              ];
            };
          }
      )
      deployedContainers
    );
  };
}
