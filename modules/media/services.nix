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
      };
    }));
  };

  # Keep the top-level config keys static (media.containers /
  # media.gateway.services). If the module's config structure were derived from
  # `mapAttrsToList ... cfg` directly, determining this module's keys would force
  # config.media.services — a self-reference that triggers infinite recursion in
  # the module system. Only the *values* below depend on cfg.
  config = {
    media.containers = mkMerge (mapAttrsToList containerOf cfg);
    media.gateway.services = mkMerge (mapAttrsToList gatewayOf cfg);
  };
}
