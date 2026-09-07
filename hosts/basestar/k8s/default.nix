# Lane A: manifests declared in nix and applied at activation.
#
# These render into services.k3s.manifests, whose content type is `attrs` or
# `listOf attrs`; a list becomes a single v1/List document. The k3s module
# links each generated file into /var/lib/rancher/k3s/server/manifests and the
# deploy controller applies it.
#
# Deleting an app from this file is NOT enough to remove it from the cluster -
# see the reconcile unit in modules/constellation/k3s.nix.
#
# Secrets never belong here: this content is rendered into the world-readable
# nix store. Use constellation.k3s.secrets instead.
{lib, ...}: let
  # A deployment, its service, its ingress and the namespace holding them.
  # Everything the common case needs and nothing it does not.
  mkApp = {
    name,
    image,
    port,
    host,
    namespace ? name,
    replicas ? 1,
    env ? {},
  }: [
    {
      apiVersion = "v1";
      kind = "Namespace";
      metadata.name = namespace;
    }
    {
      apiVersion = "apps/v1";
      kind = "Deployment";
      metadata = {inherit name namespace;};
      spec = {
        inherit replicas;
        selector.matchLabels.app = name;
        template = {
          metadata.labels.app = name;
          spec.containers = [
            {
              inherit name image;
              ports = [{containerPort = port;}];
              env =
                lib.mapAttrsToList
                (n: v: {
                  name = n;
                  value = toString v;
                })
                env;
            }
          ];
        };
      };
    }
    {
      apiVersion = "v1";
      kind = "Service";
      metadata = {inherit name namespace;};
      spec = {
        selector.app = name;
        ports = [
          {
            inherit port;
            targetPort = port;
          }
        ];
      };
    }
    {
      apiVersion = "networking.k8s.io/v1";
      kind = "Ingress";
      metadata = {inherit name namespace;};
      spec.rules = [
        {
          inherit host;
          http.paths = [
            {
              path = "/";
              pathType = "Prefix";
              backend.service = {
                inherit name;
                port.number = port;
              };
            }
          ];
        }
      ];
    }
  ];
in {
  services.k3s.manifests.whoami.content = mkApp {
    name = "whoami";
    image = "traefik/whoami:latest";
    port = 80;
    host = "whoami.arsfeld.dev";
  };
}
