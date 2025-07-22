# Example usage in your NixOS configuration
{
  config,
  pkgs,
  ...
}: {
  # Import the NAT-PMP module
  imports = [
    ./packages/natpmp-server/module.nix
  ];

  # Enable and configure the NAT-PMP server
  services.natpmp-server = {
    enable = true;

    # Set your interfaces
    externalInterface = "eth0"; # Your WAN interface
    listenInterface = "br-lan"; # Your LAN interface

    # Optional: Customize settings
    maxMappingsPerClient = 50;
    defaultLifetime = 7200; # 2 hours

    # Optional: Restrict port ranges
    allowedPortRanges = [
      {
        from = 1024;
        to = 65535;
      }
    ];
  };

  # The module automatically:
  # - Opens UDP port 5351 in the firewall
  # - Creates necessary nftables chains
  # - Runs with minimal privileges
  # - Persists mappings across restarts
}
