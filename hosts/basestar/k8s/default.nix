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
  # Kubernetes env values are strings, full stop. Naive `toString` gets there
  # for strings and numbers but is wrong for the other two Nix types callers
  # actually reach for: `toString true` gives "1" (fine for k8s, but not what
  # a Bool env var conventionally reads as), and `toString false` /
  # `toString null` both give "" — a caller writing `env.DEBUG = false;`
  # would silently get `DEBUG=""`, indistinguishable from an unset/empty
  # value. Render bools as the literal words and refuse null outright rather
  # than let it decay into an empty string.
  coerceEnvValue = n: v:
    if v == null
    then throw "mkApp: env.${n} is null - pass an explicit value, not null"
    else if lib.isBool v
    then lib.boolToString v
    else toString v;

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
    # Modest defaults, not tuned to any particular app: basestar shares 24GB
    # with blog, plausible, planka, siyuan and five podman containers, not a
    # dedicated cluster. An unbounded pod here can starve those. Callers that
    # need more pass `resources` explicitly; this is a safety floor, not a
    # recommendation.
    resources ? {
      requests = {
        cpu = "50m";
        memory = "64Mi";
      };
      limits = {
        cpu = "500m";
        memory = "256Mi";
      };
    },
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
              inherit name image resources;
              ports = [{containerPort = port;}];
              env =
                lib.mapAttrsToList
                (n: v: {
                  name = n;
                  value = coerceEnvValue n v;
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
  # No apps declared. `mkApp` above is the entry point:
  #
  #   services.k3s.manifests.<name>.content = mkApp {
  #     name = "<name>"; image = "..."; port = 80; host = "<name>.arsfeld.dev";
  #   };
  #
  # Deleting such a block again is all that is needed - k3s-manifest-reconcile
  # in modules/constellation/k3s.nix deletes the objects, the AddOn and the
  # stale symlink on the next activation. That is how the whoami fixture this
  # file used to carry was removed, and proving that is what retired it.
}
