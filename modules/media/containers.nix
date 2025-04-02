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
  utils = import "${self}/modules/media/__utils.nix" {inherit config lib;};
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
          description = "Enable media container";
        };
        name = mkOption {
          type = types.str;
          default = config._module.args.name;
          description = "Name of the container";
        };
        listenPort = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = "Port the container listens on";
        };
        exposePort = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = "Port to expose to the host";
        };
        image = mkOption {
          type = types.str;
          default = "ghcr.io/linuxserver/${config.name}";
          description = "Docker image name (defaults to ghcr.io/linuxserver/<name>)";
        };
        volumes = mkOption {
          type = types.listOf types.str;
          default = [];
          description = "Additional volumes to mount";
        };
        environment = mkOption {
          type = types.attrs;
          default = {};
          description = "Additional environment variables";
        };
        extraOptions = mkOption {
          type = types.listOf types.str;
          default = [];
          description = "Additional docker run options";
        };
        configDir = mkOption {
          type = types.nullOr types.str;
          default = "/config";
          description = "Container config directory";
        };
        mediaVolumes = mkOption {
          type = types.bool;
          default = false;
          description = "Mount media volumes";
        };
        network = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Network to use for the container";
        };
        privileged = mkOption {
          type = types.bool;
          default = false;
          description = "Run the container in privileged mode";
        };
        devices = mkOption {
          type = types.listOf types.str;
          default = [];
          description = "Devices to use for the container";
        };
        host = mkOption {
          type = types.str;
          default = _config.networking.hostName;
          description = "Host to use for the container";
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
          settings = container.settings;
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
                  "${vars.storageDir}/media:/media"
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
