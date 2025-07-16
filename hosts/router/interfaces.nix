# Router interface configuration
# This file defines the network interface names for the router
# It can be included in the main configuration to override default values
{
  config,
  lib,
  pkgs,
  ...
}: {
  # Define interface names for production router
  # Adjust these based on your actual hardware
  router.interfaces = {
    wan = "enp2s0"; # WAN interface (MAC: 60:be:b4:0d:63:30, Link: UP)
    lan1 = "enp3s0"; # First LAN port (MAC: 60:be:b4:0d:63:31, Link: DOWN)
    lan2 = "enp4s0"; # Second LAN port (MAC: 60:be:b4:0d:63:32, Link: DOWN)
    lan3 = "enp5s0"; # Third LAN port (MAC: 60:be:b4:0d:63:33, Link: DOWN)
  };
}
