# Unified declarative service definitions.
#
# `media.services.<name>` is the single entry point for declaring a service. It
# replaces the former `mkService` function helper: instead of
#   let mkService = import .../__mkService.nix {inherit lib;};
#   in lib.mkMerge [ (mkService "foo" {...}) ];
# a service file is now a plain module:
#   { media.services.foo = {...}; }
#
# Each entry is *lowered* into the existing media.containers.<name> /
# media.gateway.services.<name> options (unchanged underneath). Those two
# options are lowering targets only: the assertions at the bottom of this file
# reject a definition of either from any file outside modules/_legacy/media/.
{
  self,
  config,
  options,
  lib,
  ...
}: let
  cfg = config.media.services;
  backend = config.virtualisation.oci-containers.backend;
  # Podman bridge subnet — containers reach host postgres from here.
  podmanSubnet = "10.88.0.0/16";

  # Reject definitions of a lower-layer option from any file outside
  # modules/_legacy/media/. `opt.files` lists each file whose definition survived
  # mkIf (or, with none, the file declaring the option's default) as a store
  # path; relPath strips the store prefix for matching and for the message.
  guardLowerLayer = path: opt: let
    relPath = f: lib.last (lib.splitString "-source/" f);
    strays = lib.unique (lib.filter (f: !lib.hasPrefix "modules/_legacy/media/" (relPath f)) opt.files);
  in {
    assertion = strays == [];
    message = ''
      ${path} is written only by media.services; declare media.services.<name> instead.
      Defined directly in: ${lib.concatMapStringsSep ", " relPath strays}
    '';
  };

  # Settings forwarded to the gateway entry for a service.
  serviceSettings = svc: {inherit (svc) bypassAuth cors funnel insecureTls;};

  # Extras only the caller can know about — auto-created gateway entries from
  # media.containers don't set host or exposeViaTailscale.
  gatewayExtrasOf = svc:
    lib.optionalAttrs svc.tailscaleExposed {exposeViaTailscale = true;}
    // lib.optionalAttrs (svc.host != null) {host = lib.mkForce svc.host;};

  # Lower a container service into its media.containers.<name> body. Mirrors the
  # container branch of the former __mkService.nix.
  containerOf = name: svc:
    lib.optionalAttrs (svc.container != null) {
      ${name} =
        {
          listenPort = svc.port;
          inherit (svc) image watchImage;
          settings = serviceSettings svc;
        }
        // lib.optionalAttrs (svc.cmd != null) {cmd = svc.cmd;}
        // svc.container;
    };

  # Lower a service into its media.gateway.services.<name> entry. For container
  # services this only contributes the caller-only gatewayExtras (when any);
  # for gateway-only services it mirrors the gateway branch of __mkService.nix.
  gatewayOf = name: svc: let
    gatewayExtras = gatewayExtrasOf svc;
  in
    if svc.container != null
    # A disabled container gets no gateway entry, so it must not get extras
    # either: they alone would create one, pointing at nothing.
    then lib.optionalAttrs (gatewayExtras != {} && svc.container.enable or true) {${name} = gatewayExtras;}
    else {
      ${name} =
        gatewayExtras
        // lib.optionalAttrs (svc.port != null) {port = svc.port;}
        // {settings = lib.mkDefault (serviceSettings svc);};
    };

  # --- database.postgres lowering ---
  # Each helper returns a value guarded by mkIf so the top-level config keys stay
  # static (no recursion) while only enabled services contribute anything.

  # PostgreSQL server provisioning: db + role + trust pg_hba for the podman bridge.
  pgServerOf = name: svc:
    lib.mkIf svc.database.postgres.enable (let
      db = svc.database.postgres.name;
    in {
      enable = true;
      enableTCPIP = true;
      settings.listen_addresses = lib.mkDefault "*";
      ensureDatabases = [db];
      ensureUsers = [
        {
          name = db;
          ensureDBOwnership = true;
        }
      ];
      # TCP analogue of peer auth: passwordless from the podman bridge only.
      authentication = lib.mkAfter "host ${db} ${db} ${podmanSubnet} trust\n";
    });

  # Order the container unit after its database.
  pgUnitOf = name: svc:
    lib.mkIf (svc.database.postgres.enable && svc.container != null) {
      "${backend}-${name}" = {
        after = ["postgresql.service"];
        wants = ["postgresql.service"];
      };
    };

  # Inject a passwordless connection into the container env. The container reaches
  # the host postgres via host.containers.internal (podman). Merges with the
  # container's own environment (types.attrs).
  pgEnvOf = name: svc:
    lib.mkIf (svc.database.postgres.enable && svc.container != null) (let
      db = svc.database.postgres.name;
    in {
      ${name}.environment = {
        DATABASE_URL = "postgresql://${db}@host.containers.internal:5432/${db}";
        PGHOST = "host.containers.internal";
        PGPORT = "5432";
        PGDATABASE = db;
        PGUSER = db;
      };
    });
in {
  imports = [./containers.nix];

  options.media.services = lib.mkOption {
    default = {};
    description = ''
      Unified declarative service definitions. The single supported way to
      declare a service; lowers into media.containers / media.gateway.services.
    '';
    type = lib.types.attrsOf (lib.types.submodule ({name, ...}: {
      options = {
        port = lib.mkOption {
          type = lib.types.nullOr lib.types.int;
          default = null;
          description = "Service port. Required for container services; null = auto-assigned for gateway-only.";
        };
        image = lib.mkOption {
          type = lib.types.str;
          default = "ghcr.io/linuxserver/${name}";
          description = "Container image. Defaults to the LinuxServer.io image for the service name.";
        };
        container = lib.mkOption {
          # The body is validated downstream by the media.containers submodule;
          # keep it permissive here to avoid duplicating that option set.
          type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
          default = null;
          description = "Container body (forwarded into media.containers.<name>). null = gateway-only.";
        };
        cmd = lib.mkOption {
          type = lib.types.nullOr (lib.types.listOf lib.types.str);
          default = null;
          description = "Container command.";
        };
        host = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Gateway host override (e.g. VPN namespace IP). Lowered with mkForce.";
        };
        bypassAuth = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Skip Authelia for this service.";
        };
        cors = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable CORS headers for this service.";
        };
        funnel = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Expose publicly via Tailscale Funnel.";
        };
        insecureTls = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Backend serves a self-signed cert; skip TLS verification.";
        };
        tailscaleExposed = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Create a dedicated <name>.bat-boa.ts.net node via tsnsrv.";
        };
        watchImage = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Poll the registry and restart the container on a new image.";
        };
        database = lib.mkOption {
          default = {};
          description = "Declarative database dependencies for this service.";
          type = lib.types.submodule {
            options = {
              postgres = lib.mkOption {
                default = false;
                description = ''
                  Provision a local PostgreSQL database + role for this service,
                  reachable from the container over the podman bridge with trust
                  auth (passwordless). Set to true for defaults, or an attrset to
                  override the database/role name. A service using this must NOT
                  also set DATABASE_URL/PG* in its own container.environment: the
                  injected vars and the service's own environment merge with `//`
                  (last-wins), so a manual override would silently win.
                '';
                # `true` -> { enable = true; }; an attrset enables via the inner
                # `enable` default (true), so `{name = "x";}` provisions too.
                type = lib.types.coercedTo lib.types.bool (b: {enable = b;}) (lib.types.submodule {
                  options = {
                    enable = lib.mkOption {
                      type = lib.types.bool;
                      default = true;
                      description = "Whether to provision postgres. Defaults to true when database.postgres is set to an attrset; the option as a whole defaults to disabled.";
                    };
                    name = lib.mkOption {
                      type = lib.types.str;
                      default = name;
                      description = "Database and role name. Defaults to the service name.";
                    };
                  };
                });
              };
            };
          };
        };
      };
    }));
  };

  # Keep the top-level config keys static (media.containers /
  # media.gateway.services). If the module's config structure were derived from
  # `mapAttrsToList ... cfg` directly, determining this module's keys would force
  # config.media.services — a self-reference that triggers infinite recursion in
  # the module system. Only the *values* below depend on cfg.
  config = {
    media.containers = lib.mkMerge (
      (lib.mapAttrsToList containerOf cfg)
      ++ (lib.mapAttrsToList pgEnvOf cfg)
    );
    media.gateway.services = lib.mkMerge (lib.mapAttrsToList gatewayOf cfg);
    services.postgresql = lib.mkMerge (lib.mapAttrsToList pgServerOf cfg);
    systemd.services = lib.mkMerge (lib.mapAttrsToList pgUnitOf cfg);
    assertions = [
      (guardLowerLayer "media.gateway.services" options.media.gateway.services)
      (guardLowerLayer "media.containers" options.media.containers)
    ];
  };
}
