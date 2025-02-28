{
  self,
  config,
  lib,
  ...
}: let
  vars = config.mediaConfig;
  ports = (import "${self}/common/services.nix" {}).ports;
  nameToPort = import "${self}/common/nameToPort.nix";
in {
  options.services.mediaContainers = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        enable = lib.mkEnableOption "media container";
        listenPort = lib.mkOption {
          type = lib.types.nullOr lib.types.int;
          default = null;
          description = "Port the container listens on";
        };
        exposePort = lib.mkOption {
          type = lib.types.nullOr lib.types.int;
          default = null;
          description = "Port to expose to the host";
        };
        imageName = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "Docker image name (defaults to ghcr.io/linuxserver/<name>)";
        };
        volumes = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Additional volumes to mount";
        };
        extraEnv = lib.mkOption {
          type = lib.types.attrs;
          default = {};
          description = "Additional environment variables";
        };
        extraOptions = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Additional docker run options";
        };
        configDir = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = "/config";
          description = "Container config directory";
        };
        mediaVolumes = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Mount media volumes";
        };
      };
    });
    default = {};
    description = "Media container definitions";
  };

  config = {
    virtualisation.oci-containers.containers = lib.mkMerge (
      lib.mapAttrsToList (
        name: container:
          lib.mkIf container.enable {
            ${name} = {
              image =
                if container.imageName == ""
                then "ghcr.io/linuxserver/${name}"
                else container.imageName;
              environment =
                {
                  PUID = toString vars.puid;
                  PGID = toString vars.pgid;
                  TZ = vars.tz;
                }
                // container.extraEnv;
              ports = let
                exposePort =
                  if container.exposePort != null
                  then container.exposePort
                  else if (ports ? ${name})
                  then ports.${name}
                  else nameToPort name;
                portMapping = "${toString exposePort}:${toString container.listenPort}";
              in
                if container.listenPort != null && exposePort != null
                then [portMapping]
                else [];
              volumes =
                container.volumes
                ++ (lib.optional (container.configDir != null) "${vars.configDir}/${name}:${container.configDir}")
                ++ (lib.optionals container.mediaVolumes [
                  "${vars.dataDir}/files:/files"
                  "${vars.storageDir}/media:/media"
                ]);
              extraOptions = container.extraOptions;
            };
          }
      )
      config.services.mediaContainers
    );
  };
}
