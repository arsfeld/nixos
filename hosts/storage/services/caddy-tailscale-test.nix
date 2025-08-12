# Minimal test configuration for Caddy Tailscale gateway
#
# This configuration starts with just a few non-critical services
# to verify the Caddy Tailscale integration works correctly before
# migrating all services.
{
  config,
  lib,
  ...
}: let
  # Get port numbers from the nameToPort mapping
  nameToPort = import ../../../common/nameToPort.nix;
in {
  # Enable the new Caddy Tailscale gateway with minimal services
  constellation.caddyTailscale = {
    enable = true;

    # Start with just 3 internal services for testing
    services = {
      # Test with Speedtest (simple service, no auth needed)
      speedtest = {
        port = 8765;
        auth = "none";
        funnel = false;
      };

      # Test with Homepage (dashboard, useful for monitoring)
      homepage = {
        port = 3000;
        auth = "none";
        funnel = false;
      };

      # Test with Syncthing (more complex, has its own web UI)
      syncthing = {
        port = 8384;
        auth = "none";
        funnel = false;
      };
    };
  };

  # Keep the old tsnsrv services running for everything else
  # Only disable tsnsrv for the test services
  services.tsnsrv.services = lib.mkForce (
    lib.filterAttrs (
      name: _:
        !(lib.elem name ["speedtest" "homepage" "syncthing"])
    )
    config.services.tsnsrv.services
  );
}
