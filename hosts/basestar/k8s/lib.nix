# Helpers shared by Lane A manifests. Called as `import ./lib.nix {inherit lib;}`.
#
# This is not a NixOS module and must never become one: it sits inside a
# directory that hosts/basestar/configuration.nix imports as a module path, and
# only ./default.nix is picked up from there. A second module here would be
# silently ignored; a plain function cannot be.
#
# It exists so app #2 does not have to live in default.nix or copy mkApp. There
# is exactly one app-shaped helper today, and hoisting it before a second caller
# appears is cheaper than de-duplicating afterwards.
{lib}: rec {
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
}
