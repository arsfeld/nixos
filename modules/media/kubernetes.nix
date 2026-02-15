# Media Kubernetes module
#
# This module translates media container definitions to Kubernetes manifests
# for deployment via k3s. It provides a declarative way to deploy containerized
# services on Kubernetes while maintaining compatibility with the existing
# Podman-based container definitions.
#
# Key features:
# - Automatic translation of media.containers to Kubernetes Deployments/Services
# - NodeSelector based on container.host for multi-node scheduling
# - HostPath volumes for persistent storage
# - Environment variable and secret handling
# - NodePort service exposure for Caddy gateway integration
#
# Translation mapping:
# | media.containers      | Kubernetes                              |
# |----------------------|------------------------------------------|
# | listenPort           | Service (NodePort) + Container port      |
# | mediaVolumes = true  | HostPath PV at /mnt/storage/media       |
# | devices = ["/dev/dri"] | privileged + hostPath                 |
# | network = "host"     | hostNetwork: true                       |
# | host = "storage"     | nodeSelector                            |
# | environmentFiles     | Secret + envFrom                        |
{
  self,
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  _config = config;
  cfg = config.media.kubernetes;
  vars = config.media.config;
  containers = config.media.containers;
  nameToPort = import "${self}/common/nameToPort.nix";

  # Filter containers that should be deployed on this host
  deployedContainers =
    filterAttrs
    (name: container: container.enable && container.host == config.networking.hostName)
    containers;

  # Filter containers that need a Kubernetes Service (have a listenPort)
  exposedContainers =
    filterAttrs
    (name: container: container.enable && container.listenPort != null)
    containers;

  # Generate a Kubernetes Deployment for a container
  mkDeployment = name: container: {
    apiVersion = "apps/v1";
    kind = "Deployment";
    metadata = {
      inherit name;
      namespace = cfg.namespace;
      labels.app = name;
    };
    spec = {
      replicas = 1;
      selector.matchLabels.app = name;
      template = {
        metadata.labels.app = name;
        spec = {
          # Schedule on the correct host
          nodeSelector."kubernetes.io/hostname" = container.host;

          # Graceful shutdown
          terminationGracePeriodSeconds = 30;

          # Use host network if specified
          hostNetwork = container.network == "host";
          dnsPolicy =
            if container.network == "host"
            then "ClusterFirstWithHostNet"
            else "ClusterFirst";

          # Security context for devices
          securityContext = mkIf (container.devices != [] || container.privileged) {
            privileged = container.privileged || container.devices != [];
          };

          containers = [
            {
              inherit name;
              image = container.image;
              imagePullPolicy = "Always";

              # Container ports
              ports = optional (container.listenPort != null) {
                containerPort = container.listenPort;
                protocol = "TCP";
              };

              # Environment variables
              env =
                [
                  {
                    name = "PUID";
                    value = toString vars.puid;
                  }
                  {
                    name = "PGID";
                    value = toString vars.pgid;
                  }
                  {
                    name = "TZ";
                    value = vars.tz;
                  }
                ]
                ++ (mapAttrsToList (k: v: {
                    name = k;
                    value = toString v;
                  })
                  container.environment);

              # Environment from secrets (for environmentFiles)
              envFrom = optional (container.environmentFiles != []) {
                secretRef.name = "${name}-env";
              };

              # Volume mounts
              volumeMounts = let
                configMount = optional (container.configDir != null) {
                  name = "config";
                  mountPath = container.configDir;
                };
                mediaMount = optionals container.mediaVolumes [
                  {
                    name = "media";
                    mountPath = "/media";
                  }
                  {
                    name = "files";
                    mountPath = "/files";
                  }
                ];
                deviceMounts =
                  map (device: let
                    devicePath = builtins.head (builtins.split ":" device);
                  in {
                    name = "device-${replaceStrings ["/"] ["-"] devicePath}";
                    mountPath = devicePath;
                  })
                  container.devices;
                customMounts =
                  imap0 (i: volume: let
                    parts = builtins.split ":" volume;
                    containerPath = builtins.elemAt parts 2;
                  in {
                    name = "volume-${toString i}";
                    mountPath = containerPath;
                  })
                  container.volumes;
              in
                configMount ++ mediaMount ++ deviceMounts ++ customMounts;

              # Resource limits (optional, can be extended)
              resources = {
                requests = {
                  memory = "128Mi";
                  cpu = "100m";
                };
                limits = {
                  memory = "2Gi";
                  cpu = "2000m";
                };
              };
            }
          ];

          # Volumes
          volumes = let
            configVolume = optional (container.configDir != null) {
              name = "config";
              hostPath = {
                path = "${vars.configDir}/${name}";
                type = "DirectoryOrCreate";
              };
            };
            mediaVolumes = optionals container.mediaVolumes [
              {
                name = "media";
                hostPath = {
                  path = "${vars.storageDir}/media";
                  type = "Directory";
                };
              }
              {
                name = "files";
                hostPath = {
                  path = "${vars.dataDir}/files";
                  type = "DirectoryOrCreate";
                };
              }
            ];
            deviceVolumes =
              map (device: let
                devicePath = builtins.head (builtins.split ":" device);
              in {
                name = "device-${replaceStrings ["/"] ["-"] devicePath}";
                hostPath = {
                  path = devicePath;
                  type = "CharDevice";
                };
              })
              container.devices;
            customVolumes =
              imap0 (i: volume: let
                parts = builtins.split ":" volume;
                hostPath = builtins.elemAt parts 0;
              in {
                name = "volume-${toString i}";
                hostPath = {
                  path = hostPath;
                  type = "DirectoryOrCreate";
                };
              })
              container.volumes;
          in
            configVolume ++ mediaVolumes ++ deviceVolumes ++ customVolumes;
        };
      };
    };
  };

  # Generate a Kubernetes Service for a container
  mkService = name: container: let
    exposePort =
      if container.exposePort != null
      then container.exposePort
      else nameToPort name;
  in {
    apiVersion = "v1";
    kind = "Service";
    metadata = {
      inherit name;
      namespace = cfg.namespace;
      labels.app = name;
      annotations =
        {}
        // (optionalAttrs (container.settings.funnel or false) {
          "tailscale.com/expose" = "true";
          "tailscale.com/funnel" = "true";
        })
        // (optionalAttrs (config.media.gateway.services.${name}.exposeViaTailscale or false) {
          "tailscale.com/expose" = "true";
        });
    };
    spec = {
      type = "NodePort";
      selector.app = name;
      ports = [
        {
          port = container.listenPort;
          targetPort = container.listenPort;
          nodePort = exposePort;
          protocol = "TCP";
        }
      ];
    };
  };

  # Generate a Kubernetes Secret for environment files
  # Note: This is a placeholder - actual secrets should be managed via sops-nix
  mkEnvSecret = name: container: {
    apiVersion = "v1";
    kind = "Secret";
    metadata = {
      name = "${name}-env";
      namespace = cfg.namespace;
    };
    type = "Opaque";
    # Data will be populated by sops-secrets-operator or external-secrets
    stringData = {};
  };

  # Generate all manifests for a container
  mkContainerManifests = name: container:
    {
      "${name}-deployment" = mkDeployment name container;
    }
    // (optionalAttrs (container.listenPort != null) {
      "${name}-service" = mkService name container;
    })
    // (optionalAttrs (container.environmentFiles != []) {
      "${name}-env-secret" = mkEnvSecret name container;
    });

  # Generate namespace manifest
  namespaceManifest = {
    "${cfg.namespace}-namespace" = {
      apiVersion = "v1";
      kind = "Namespace";
      metadata.name = cfg.namespace;
    };
  };
in {
  options.media.kubernetes = {
    enable = mkEnableOption "Kubernetes backend for media containers";

    namespace = mkOption {
      type = types.str;
      default = "media";
      description = "Kubernetes namespace for media services.";
    };

    manifests = mkOption {
      type = types.attrsOf types.anything;
      default = {};
      description = ''
        Additional Kubernetes manifests to deploy alongside container manifests.
        These are merged with auto-generated manifests.
      '';
    };
  };

  config = mkIf (cfg.enable && config.constellation.k3s.enable) {
    # Generate k3s manifests from container definitions
    constellation.k3s.manifests =
      namespaceManifest
      // (foldl' (acc: name: acc // mkContainerManifests name deployedContainers.${name}) {} (attrNames deployedContainers))
      // cfg.manifests;

    # Ensure required directories exist for HostPath volumes
    systemd.tmpfiles.rules = let
      createDir = path: "d ${path} 0775 ${vars.user} ${vars.group} -";
    in
      flatten (
        mapAttrsToList (
          name: container: (optional (container.configDir != null) (createDir "${vars.configDir}/${name}"))
        )
        deployedContainers
      );

    # Create Kubernetes secrets from sops-nix secrets
    # This generates script to populate secrets from decrypted files
    systemd.services.k3s-secrets-sync = mkIf (config.constellation.sops.enable) {
      description = "Sync sops secrets to Kubernetes";
      after = ["k3s.service"];
      wants = ["k3s.service"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = let
        kubectl = "${pkgs.kubectl}/bin/kubectl";
        secretsWithEnvFiles = filterAttrs (name: container: container.environmentFiles != []) deployedContainers;
      in ''
        # Wait for k3s to be ready
        while ! ${kubectl} get namespace default >/dev/null 2>&1; do
          echo "Waiting for k3s to be ready..."
          sleep 5
        done

        # Ensure namespace exists
        ${kubectl} create namespace ${cfg.namespace} --dry-run=client -o yaml | ${kubectl} apply -f -

        ${concatMapStrings (name: let
          container = deployedContainers.${name};
        in ''
          # Create secret for ${name}
          ${kubectl} create secret generic ${name}-env \
            --namespace ${cfg.namespace} \
            --dry-run=client -o yaml \
            ${concatMapStrings (file: ''--from-env-file="${file}" '') container.environmentFiles} \
            | ${kubectl} apply -f -
        '') (attrNames secretsWithEnvFiles)}

        echo "Secrets synced successfully"
      '';
    };
  };
}
