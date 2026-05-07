# mkService - Helper function for declaring media services
#
# Creates a NixOS config attrset for use with lib.mkMerge.
# For container services, populates media.containers (which auto-creates
# the matching media.gateway.services entry when listenPort is set).
# For non-container services, populates media.gateway.services directly.
#
# Usage:
#   mkService "jellyfin" {
#     port = 8096;
#     container = { mediaVolumes = true; devices = ["/dev/dri:/dev/dri"]; };
#     bypassAuth = true;
#     tailscaleExposed = true;
#   }
{lib}: name: {
  # Service port. Required for container services. For gateway-only services,
  # null falls back to the auto-assigned port from common/nameToPort.nix.
  port ? null,
  image ? "ghcr.io/linuxserver/${name}",
  # Container body (forwarded into media.containers.<name>). When null, the
  # service is gateway-only (e.g. a native NixOS service or no backend).
  container ? null,
  # Container command (only meaningful when container != null).
  cmd ? null,
  # Gateway host override (e.g. VPN namespace IP). Wrapped in lib.mkForce
  # so callers can override defaults set elsewhere.
  host ? null,
  bypassAuth ? false,
  cors ? false,
  funnel ? false,
  insecureTls ? false,
  tailscaleExposed ? false,
  watchImage ? false,
}: let
  settings = {inherit bypassAuth cors funnel insecureTls;};
  # Extras only the caller can know about — auto-created gateway entries from
  # media.containers don't set host or exposeViaTailscale.
  gatewayExtras =
    lib.optionalAttrs tailscaleExposed {exposeViaTailscale = true;}
    // lib.optionalAttrs (host != null) {host = lib.mkForce host;};
in
  if container != null
  then
    lib.recursiveUpdate
    {
      media.containers.${name} =
        {
          listenPort = port;
          inherit image settings watchImage;
        }
        // lib.optionalAttrs (cmd != null) {inherit cmd;}
        // container;
    }
    (lib.optionalAttrs (gatewayExtras != {}) {
      media.gateway.services.${name} = gatewayExtras;
    })
  else {
    media.gateway.services.${name} =
      gatewayExtras
      // lib.optionalAttrs (port != null) {inherit port;}
      // {settings = lib.mkDefault settings;};
  }
