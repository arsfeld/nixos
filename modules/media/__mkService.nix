# mkService - Helper function for declaring media services
#
# Creates a NixOS config attrset for use with lib.mkMerge.
# For container services, populates media.containers.
# For non-container services, populates media.gateway.services.
#
# Usage:
#   mkService "jellyfin" {
#     port = 8096;
#     container = { mediaVolumes = true; devices = ["/dev/dri:/dev/dri"]; };
#     bypassAuth = true;
#     tailscaleExposed = true;
#   }
{lib}: name: {
  port,
  image ? "ghcr.io/linuxserver/${name}",
  container ? null,
  bypassAuth ? false,
  cors ? false,
  funnel ? false,
  insecureTls ? false,
  tailscaleExposed ? false,
  watchImage ? false,
}: let
  settings = {inherit bypassAuth cors funnel insecureTls;};
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
        // container;
    }
    (lib.optionalAttrs tailscaleExposed {
      media.gateway.services.${name}.exposeViaTailscale = true;
    })
  else {
    media.gateway.services.${name} = {
      inherit port;
      exposeViaTailscale = tailscaleExposed;
      settings = lib.mkDefault settings;
    };
  }
