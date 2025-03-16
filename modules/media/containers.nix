{
  self,
  config,
  lib,
  ...
}: with lib; let
  vars = config.media.config;
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
            default = config.networking.hostName;
            description = "Host to use for the container";
          };
        };
      }));
      default = {};
      description = "Media container definitions";
    };

    config = mkIf (cfg != {}) {
      media.gateway = {
        enable = mkDefault (length (attrValues exposedContainers) > 0);
        # Define ports first so we can reference them in services
        ports =
          mapAttrs
          (
            name: container:
              if container.exposePort != null
              then container.exposePort
              else nameToPort name
          )
          exposedContainers;

        services = let
          # Build a nested attribute set for each enabled container with a listenPort
          containerServices =
            mapAttrs
            (
              name: container: {
                ${container.host} = {
                  ${name} = config.media.gateway.ports.${name};
                };
              }
            )
            exposedContainers;

          # Merge all container entries by host
          mergedByHost =
            foldl
            (
              acc: container:
                recursiveUpdate acc container
            )
            {}
            (attrValues containerServices);
        in
          mergedByHost;
      };

      systemd.tmpfiles.rules =
        mapAttrsToList (
          name: container:
            if container.configDir != null
            then "d ${vars.configDir}/${name} 0775 ${vars.user} ${vars.group} -"
            else ""
        )
        deployedContainers;

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
                  exposePort =
                    if container.exposePort != null
                    then container.exposePort
                    else if (config.media.gateway.ports ? ${name})
                    then config.media.gateway.ports.${name}
                    else nameToPort name;
                  portMapping = "${toString exposePort}:${toString container.listenPort}";
                in
                  if container.listenPort != null && exposePort != null
                  then [portMapping]
                  else [];
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
