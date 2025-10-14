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

  # Note: Both tsnsrv and Caddy will run for these test services temporarily
  # Once we verify Caddy works, we'll do the full migration
}
