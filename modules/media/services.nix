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
# options remain implementation/lowering targets and should not be written by
# hand.
{
  self,
  config,
  lib,
  ...
}:
with lib; let
  cfg = config.media.services;
  backend = config.virtualisation.oci-containers.backend;
  # Podman bridge subnet — containers reach host postgres from here.
  podmanSubnet = "10.88.0.0/16";

  # Settings forwarded to the gateway entry for a service.
  serviceSettings = svc: {inherit (svc) bypassAuth cors funnel insecureTls;};

  # Extras only the caller can know about — auto-created gateway entries from
  # media.containers don't set host or exposeViaTailscale.
  gatewayExtrasOf = svc:
    optionalAttrs svc.tailscaleExposed {exposeViaTailscale = true;}
    // optionalAttrs (svc.host != null) {host = mkForce svc.host;};

  # Lower a container service into its media.containers.<name> body. Mirrors the
  # container branch of the former __mkService.nix.
  containerOf = name: svc:
    optionalAttrs (svc.container != null) {
      ${name} =
        {
          listenPort = svc.port;
          inherit (svc) image watchImage;
          settings = serviceSettings svc;
        }
        // optionalAttrs (svc.cmd != null) {cmd = svc.cmd;}
        // svc.container;
    };

  # Lower a service into its media.gateway.services.<name> entry. For container
  # services this only contributes the caller-only gatewayExtras (when any);
  # for gateway-only services it mirrors the gateway branch of __mkService.nix.
  gatewayOf = name: svc: let
    gatewayExtras = gatewayExtrasOf svc;
  in
    if svc.container != null
    then optionalAttrs (gatewayExtras != {}) {${name} = gatewayExtras;}
    else {
      ${name} =
        gatewayExtras
        // optionalAttrs (svc.port != null) {port = svc.port;}
        // {settings = mkDefault (serviceSettings svc);};
    };

  # --- database.postgres lowering ---
  # Each helper returns a value guarded by mkIf so the top-level config keys stay
  # static (no recursion) while only enabled services contribute anything.

  # PostgreSQL server provisioning: db + role + trust pg_hba for the podman bridge.
  pgServerOf = name: svc:
    mkIf svc.database.postgres.enable (let
      db = svc.database.postgres.name;
    in {
      enable = true;
      enableTCPIP = true;
      settings.listen_addresses = mkDefault "*";
      ensureDatabases = [db];
      ensureUsers = [
        {
          name = db;
          ensureDBOwnership = true;
        }
      ];
      # TCP analogue of peer auth: passwordless from the podman bridge only.
      authentication = mkAfter "host ${db} ${db} ${podmanSubnet} trust\n";
    });

  # Order the container unit after its database.
  pgUnitOf = name: svc:
    mkIf (svc.database.postgres.enable && svc.container != null) {
      "${backend}-${name}" = {
        after = ["postgresql.service"];
        wants = ["postgresql.service"];
      };
    };

  # Inject a passwordless connection into the container env. The container reaches
  # the host postgres via host.containers.internal (podman). Merges with the
  # container's own environment (types.attrs).
  pgEnvOf = name: svc:
    mkIf (svc.database.postgres.enable && svc.container != null) (let
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

  options.media.services = mkOption {
    default = {};
    description = ''
      Unified declarative service definitions. The single supported way to
      declare a service; lowers into media.containers / media.gateway.services.
    '';
    type = types.attrsOf (types.submodule ({name, ...}: {
      options = {
        port = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = "Service port. Required for container services; null = auto-assigned for gateway-only.";
        };
        image = mkOption {
          type = types.str;
          default = "ghcr.io/linuxserver/${name}";
          description = "Container image. Defaults to the LinuxServer.io image for the service name.";
        };
        container = mkOption {
          # The body is validated downstream by the media.containers submodule;
          # keep it permissive here to avoid duplicating that option set.
          type = types.nullOr (types.attrsOf types.anything);
          default = null;
          description = "Container body (forwarded into media.containers.<name>). null = gateway-only.";
        };
        cmd = mkOption {
          type = types.nullOr (types.listOf types.str);
          default = null;
          description = "Container command.";
        };
        host = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Gateway host override (e.g. VPN namespace IP). Lowered with mkForce.";
        };
        bypassAuth = mkOption {
          type = types.bool;
          default = false;
          description = "Skip Authelia for this service.";
        };
        cors = mkOption {
          type = types.bool;
          default = false;
          description = "Enable CORS headers for this service.";
        };
        funnel = mkOption {
          type = types.bool;
          default = false;
          description = "Expose publicly via Tailscale Funnel.";
        };
        insecureTls = mkOption {
          type = types.bool;
          default = false;
          description = "Backend serves a self-signed cert; skip TLS verification.";
        };
        tailscaleExposed = mkOption {
          type = types.bool;
          default = false;
          description = "Create a dedicated <name>.bat-boa.ts.net node via tsnsrv.";
        };
        watchImage = mkOption {
          type = types.bool;
          default = false;
          description = "Poll the registry and restart the container on a new image.";
        };
        database = mkOption {
          default = {};
          description = "Declarative database dependencies for this service.";
          type = types.submodule {
            options = {
              postgres = mkOption {
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
                type = types.coercedTo types.bool (b: {enable = b;}) (types.submodule {
                  options = {
                    enable = mkOption {
                      type = types.bool;
                      default = true;
                      description = "Whether to provision postgres. Defaults to true when database.postgres is set to an attrset; the option as a whole defaults to disabled.";
                    };
                    name = mkOption {
                      type = types.str;
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
    media.containers = mkMerge (
      (mapAttrsToList containerOf cfg)
      ++ (mapAttrsToList pgEnvOf cfg)
    );
    media.gateway.services = mkMerge (mapAttrsToList gatewayOf cfg);
    services.postgresql = mkMerge (mapAttrsToList pgServerOf cfg);
    systemd.services = mkMerge (mapAttrsToList pgUnitOf cfg);
  };
}
